// SPDX-License-Identifier: MIT
/*
 * rl_net - Linux network interface (rl0) of the qsfp28-fmc-rocelet design on Zynq UltraScale+.
 *
 * The rocelet engine terminates RoCE v2 (UDP 4791) in the PL; every other frame of QSFP28 port 0
 * (ARP, ICMP, IP, the Holoscan Sensor Bridge control plane, ...) leaves the engine on its
 * other-traffic port and reaches Linux through the design's netdev DMA channel; frames from Linux
 * go the other way. So Linux owns the port's IP address (ARP, ICMP, sockets, tcpdump) while the
 * engine keeps the RDMA data path. Hardware contract (docs/source/zynqmp_hw.md, "Netdev DMA
 * channel"):
 *  - an AMD AXI DMA (PG021, scatter-gather, no status stream), driven through dmaengine
 *    (xilinx_dma): MM2S = tx, S2MM = rx; non-coherent HP port (the DMA API does the cache work);
 *  - one Ethernet frame per stream packet, from the destination MAC, no FCS (the MAC strips it on
 *    receive and appends it on transmit, and pads short frames); good frames only;
 *  - RX frames up to 10240 bytes (longer ones are cut at 10240: dropped here), the frame length is
 *    the S2MM descriptor's transferred bytes (xilinx_dma: buffer length - residue); every RX buffer
 *    is 10240 bytes so a frame never spans two descriptors;
 *  - the MAC (omac) receives frames up to MAX_FRAME = 9600 bytes with the FCS: MTU <= 9578;
 *  - the engine is never back-pressured: frames arriving while no S2MM descriptor is queued are
 *    dropped in the PL and counted (E_ODMA_DROP);
 *  - the always-on register block (pl_clk0, never stopped; reg 0 of this node) gives the link
 *    state (STATUS[5]) for the carrier and the link speed (CAPS[7:0]).
 * The engine side of the channel (CTRL.OTHER_RX_EN, CTRL.ARP_INT = 0, C_ODMA_CTRL, the engine's own
 * MAC / IP = rl0's) is configured by the user-space daemon roceletd, which owns the engine.
 *
 * Small frames are copied into a fresh skb (copybreak) and their DMA buffer is re-queued as it is,
 * so a 64-byte ARP does not carry the truesize of a 10 KB buffer into the socket accounting.
 *
 * Derived from the Opsero taxi_mac driver (ethernet-fmc-taxi-eth).
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */

#include <linux/bitfield.h>
#include <linux/circ_buf.h>
#include <linux/delay.h>
#include <linux/dma-mapping.h>
#include <linux/dmaengine.h>
#include <linux/etherdevice.h>
#include <linux/ethtool.h>
#include <linux/if_vlan.h>
#include <linux/io.h>
#include <linux/jiffies.h>
#include <linux/llist.h>
#include <linux/module.h>
#include <linux/netdevice.h>
#include <linux/of.h>
#include <linux/of_net.h>
#include <linux/platform_device.h>
#include <linux/scatterlist.h>
#include <linux/skbuff.h>
#include <linux/spinlock.h>
#include <linux/u64_stats_sync.h>
#include <linux/workqueue.h>

#define RL_DRV_NAME		"rl_net"
#define RL_DRV_VERSION		"1.0"

/* always-on registers (offsets inside reg 0 = the block at 0x8008_0000) */
#define AON_ID			0x00
#define AON_ID_MAGIC		0x52414F4E	/* "RAON" */
#define AON_VERSION		0x04
#define AON_TARGET		0x0c
#define AON_CAPS		0x10
#define AON_MAC_KHZ		0x14
#define AON_STATUS		0x24
#define AON_ST_ALIVE		BIT(0)
#define AON_ST_LINK		BIT(5)
#define AON_LINK_EV		0x28
#define AON_CAPS_GBPS		GENMASK(7, 0)
#define AON_CAPS_NETDEV_DMA	BIT(25)

#define RL_TX_RING		128
#define RL_TX_WAKE_THRESH	(RL_TX_RING / 4)
#define RL_RX_RING		128
#define RL_RX_BUF_LEN		10240		/* the channel's longest frame: one descriptor each */
#define RL_COPYBREAK		1536
#define RL_MAC_MAX_FRAME	9600		/* omac MAX_FRAME, with the FCS */
#define RL_MAX_MTU		(RL_MAC_MAX_FRAME - ETH_FCS_LEN - ETH_HLEN - VLAN_HLEN)
#define RL_TX_MAX_FRAME		16383		/* the engine's other-traffic FIFO */

#define RL_TX_DRAIN_MS		500
#define RL_LINK_POLL_MS		100

struct rl_priv;

struct rl_tx_buf {
	struct sk_buff *skb;
	dma_addr_t dma;
	unsigned int len;
};

struct rl_rx_buf {
	struct rl_priv *priv;
	struct sk_buff *skb;		/* RL_RX_BUF_LEN bytes, mapped while it owns the slot */
	dma_addr_t dma;
	struct llist_node node;		/* on rx_done once the DMA has completed */
	unsigned int len;
	bool error;
};

struct rl_priv {
	struct net_device *ndev;
	struct device *dev;
	void __iomem *aon;
	u32 gbps;

	struct dma_chan *tx_chan;
	struct dma_chan *rx_chan;

	struct rl_tx_buf tx_ring[RL_TX_RING];
	unsigned int tx_head;
	unsigned int tx_tail;
	spinlock_t tx_lock;

	struct rl_rx_buf rx_ring[RL_RX_RING];
	bool rx_running;
	spinlock_t rx_lock;
	struct napi_struct napi;
	struct llist_head rx_done;
	struct llist_node *rx_pending;

	struct delayed_work link_work;
	bool link_poll;

	struct u64_stats_sync tx_syncp;
	u64 tx_packets, tx_bytes, tx_errors, tx_dropped;
	struct u64_stats_sync rx_syncp;
	u64 rx_packets, rx_bytes, rx_errors, rx_dropped, rx_length_errors;
	u64 rx_copybreak, rx_long;
	u64 carrier_changes;
};

static inline u32 aon_read(struct rl_priv *priv, u32 reg)
{
	return readl(priv->aon + reg);
}

static inline struct device *rl_dma_dev(struct dma_chan *chan)
{
	return chan->device->dev;
}

/* -------------------------------------------------------------------------
 * Carrier: the always-on block's link status, polled
 */

static void rl_link_update(struct rl_priv *priv)
{
	struct net_device *ndev = priv->ndev;
	bool up = (aon_read(priv, AON_STATUS) & (AON_ST_LINK | AON_ST_ALIVE)) ==
		  (AON_ST_LINK | AON_ST_ALIVE);

	if (up == netif_carrier_ok(ndev))
		return;
	priv->carrier_changes++;
	if (up) {
		netif_carrier_on(ndev);
		netdev_info(ndev, "link up, %u Gb/s\n", priv->gbps);
	} else {
		netif_carrier_off(ndev);
		netdev_info(ndev, "link down\n");
	}
}

static void rl_link_work(struct work_struct *work)
{
	struct rl_priv *priv = container_of(to_delayed_work(work), struct rl_priv, link_work);

	rl_link_update(priv);
	if (READ_ONCE(priv->link_poll))
		schedule_delayed_work(&priv->link_work, msecs_to_jiffies(RL_LINK_POLL_MS));
}

/* -------------------------------------------------------------------------
 * Receive path
 */

static void rl_rx_complete(void *param, const struct dmaengine_result *result);

/* queue buf (its skb already mapped at buf->dma) on the S2MM channel */
static int rl_rx_queue(struct rl_priv *priv, struct rl_rx_buf *buf)
{
	struct dma_async_tx_descriptor *desc;
	struct scatterlist sg;
	dma_cookie_t cookie;

	sg_init_table(&sg, 1);
	sg_dma_address(&sg) = buf->dma;
	sg_dma_len(&sg) = RL_RX_BUF_LEN;

	desc = dmaengine_prep_slave_sg(priv->rx_chan, &sg, 1, DMA_DEV_TO_MEM,
				       DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!desc)
		return -EBUSY;
	desc->callback_result = rl_rx_complete;
	desc->callback_param = buf;
	cookie = dmaengine_submit(desc);
	return dma_submit_error(cookie) ? cookie : 0;
}

/* give buf a new skb, map it and queue it */
static int rl_rx_refill(struct rl_priv *priv, struct rl_rx_buf *buf, struct sk_buff *skb)
{
	struct device *dma_dev = rl_dma_dev(priv->rx_chan);
	dma_addr_t dma;
	int ret;

	dma = dma_map_single(dma_dev, skb->data, RL_RX_BUF_LEN, DMA_FROM_DEVICE);
	if (dma_mapping_error(dma_dev, dma))
		return -ENOMEM;
	buf->skb = skb;
	buf->dma = dma;
	ret = rl_rx_queue(priv, buf);
	if (ret) {
		dma_unmap_single(dma_dev, dma, RL_RX_BUF_LEN, DMA_FROM_DEVICE);
		buf->skb = NULL;
	}
	return ret;
}

static void rl_rx_complete(void *param, const struct dmaengine_result *result)
{
	struct rl_rx_buf *buf = param;
	struct rl_priv *priv = buf->priv;

	buf->error = result->result != DMA_TRANS_NOERROR || result->residue > RL_RX_BUF_LEN;
	buf->len = buf->error ? 0 : RL_RX_BUF_LEN - result->residue;
	llist_add(&buf->node, &priv->rx_done);
	napi_schedule(&priv->napi);
}

static void rl_rx_stat(struct rl_priv *priv, u64 *ctr)
{
	u64_stats_update_begin(&priv->rx_syncp);
	(*ctr)++;
	u64_stats_update_end(&priv->rx_syncp);
}

/* one completed buffer: deliver its frame, re-queue the slot */
static void rl_rx_process(struct rl_priv *priv, struct rl_rx_buf *buf)
{
	struct net_device *ndev = priv->ndev;
	struct device *dma_dev = rl_dma_dev(priv->rx_chan);
	struct sk_buff *skb = buf->skb, *nskb;
	unsigned int len = buf->len;
	bool requeue = true;		/* keep the current mapping and skb */
	int ret;

	if (buf->error || len < ETH_HLEN) {
		rl_rx_stat(priv, &priv->rx_errors);
		goto resubmit;
	}
	if (len >= RL_RX_BUF_LEN) {
		/* cut by the channel at 10240 bytes: not a whole frame */
		rl_rx_stat(priv, &priv->rx_length_errors);
		goto resubmit;
	}

	dma_sync_single_for_cpu(dma_dev, buf->dma, len, DMA_FROM_DEVICE);
	if (len <= RL_COPYBREAK) {
		nskb = napi_alloc_skb(&priv->napi, len);
		if (!nskb) {
			rl_rx_stat(priv, &priv->rx_dropped);
			goto resubmit;
		}
		skb_copy_to_linear_data(nskb, skb->data, len);
		u64_stats_update_begin(&priv->rx_syncp);
		priv->rx_copybreak++;
		u64_stats_update_end(&priv->rx_syncp);
	} else {
		/* hand the buffer to the stack, put a new one in the slot */
		struct sk_buff *fresh = netdev_alloc_skb_ip_align(ndev, RL_RX_BUF_LEN);

		if (!fresh) {
			rl_rx_stat(priv, &priv->rx_dropped);
			goto resubmit;
		}
		dma_unmap_single(dma_dev, buf->dma, RL_RX_BUF_LEN, DMA_FROM_DEVICE);
		buf->skb = NULL;
		nskb = skb;
		skb = fresh;
		requeue = false;
		u64_stats_update_begin(&priv->rx_syncp);
		priv->rx_long++;
		u64_stats_update_end(&priv->rx_syncp);
	}

	skb_put(nskb, len);
	nskb->protocol = eth_type_trans(nskb, ndev);
	nskb->ip_summed = CHECKSUM_NONE;
	u64_stats_update_begin(&priv->rx_syncp);
	priv->rx_packets++;
	priv->rx_bytes += len;
	u64_stats_update_end(&priv->rx_syncp);
	napi_gro_receive(&priv->napi, nskb);

resubmit:
	spin_lock(&priv->rx_lock);
	if (!priv->rx_running) {
		ret = -ENODEV;
	} else if (requeue) {
		dma_sync_single_for_device(dma_dev, buf->dma, RL_RX_BUF_LEN, DMA_FROM_DEVICE);
		ret = rl_rx_queue(priv, buf);
	} else {
		ret = rl_rx_refill(priv, buf, skb);
	}
	spin_unlock(&priv->rx_lock);

	if (ret) {
		if (requeue && buf->skb) {
			dma_unmap_single(dma_dev, buf->dma, RL_RX_BUF_LEN, DMA_FROM_DEVICE);
			dev_kfree_skb_any(buf->skb);
			buf->skb = NULL;
		} else if (!requeue) {
			dev_kfree_skb_any(skb);
		}
		if (ret != -ENODEV && net_ratelimit())
			netdev_err(ndev, "RX buffer re-queue failed (%d)\n", ret);
	}
}

static int rl_rx_poll(struct napi_struct *napi, int budget)
{
	struct rl_priv *priv = container_of(napi, struct rl_priv, napi);
	struct llist_node *node;
	int done = 0;

	while (done < budget) {
		if (!priv->rx_pending) {
			node = llist_del_all(&priv->rx_done);
			if (!node)
				break;
			priv->rx_pending = llist_reverse_order(node);
		}
		node = priv->rx_pending;
		priv->rx_pending = node->next;
		rl_rx_process(priv, llist_entry(node, struct rl_rx_buf, node));
		done++;
	}

	if (done)
		dma_async_issue_pending(priv->rx_chan);

	if (done < budget) {
		napi_complete_done(napi, done);
		if (!llist_empty(&priv->rx_done))
			napi_schedule(napi);
	}
	return done;
}

static void rl_rx_ring_stop(struct rl_priv *priv)
{
	struct device *dma_dev = rl_dma_dev(priv->rx_chan);
	unsigned int i;

	spin_lock_bh(&priv->rx_lock);
	priv->rx_running = false;
	spin_unlock_bh(&priv->rx_lock);

	dmaengine_terminate_sync(priv->rx_chan);
	napi_disable(&priv->napi);

	llist_del_all(&priv->rx_done);
	priv->rx_pending = NULL;
	for (i = 0; i < RL_RX_RING; i++) {
		struct rl_rx_buf *buf = &priv->rx_ring[i];

		if (!buf->skb)
			continue;
		dma_unmap_single(dma_dev, buf->dma, RL_RX_BUF_LEN, DMA_FROM_DEVICE);
		dev_kfree_skb(buf->skb);
		buf->skb = NULL;
	}
}

static int rl_rx_ring_start(struct rl_priv *priv)
{
	struct net_device *ndev = priv->ndev;
	unsigned int i;
	int ret;

	priv->rx_running = true;
	napi_enable(&priv->napi);

	for (i = 0; i < RL_RX_RING; i++) {
		struct rl_rx_buf *buf = &priv->rx_ring[i];
		struct sk_buff *skb;

		buf->priv = priv;
		skb = netdev_alloc_skb_ip_align(ndev, RL_RX_BUF_LEN);
		if (!skb) {
			ret = -ENOMEM;
			goto err;
		}
		ret = rl_rx_refill(priv, buf, skb);
		if (ret) {
			dev_kfree_skb(skb);
			goto err;
		}
	}
	dma_async_issue_pending(priv->rx_chan);
	return 0;

err:
	netdev_err(ndev, "failed to fill the RX ring (%d)\n", ret);
	rl_rx_ring_stop(priv);
	return ret;
}

/* -------------------------------------------------------------------------
 * Transmit path
 */

static void rl_tx_complete(void *param, const struct dmaengine_result *result)
{
	struct rl_priv *priv = param;
	struct net_device *ndev = priv->ndev;
	struct rl_tx_buf *buf;
	struct sk_buff *skb;
	unsigned long flags;

	spin_lock_irqsave(&priv->tx_lock, flags);
	if (priv->tx_tail == priv->tx_head) {
		spin_unlock_irqrestore(&priv->tx_lock, flags);
		return;
	}
	buf = &priv->tx_ring[priv->tx_tail % RL_TX_RING];
	skb = buf->skb;
	buf->skb = NULL;
	dma_unmap_single(rl_dma_dev(priv->tx_chan), buf->dma, buf->len, DMA_TO_DEVICE);

	u64_stats_update_begin(&priv->tx_syncp);
	if (result->result == DMA_TRANS_NOERROR) {
		priv->tx_packets++;
		priv->tx_bytes += buf->len;
	} else {
		priv->tx_errors++;
	}
	u64_stats_update_end(&priv->tx_syncp);

	priv->tx_tail++;
	if (netif_queue_stopped(ndev) &&
	    CIRC_SPACE(priv->tx_head, priv->tx_tail, RL_TX_RING) >= RL_TX_WAKE_THRESH)
		netif_wake_queue(ndev);
	spin_unlock_irqrestore(&priv->tx_lock, flags);

	dev_consume_skb_any(skb);
}

static netdev_tx_t rl_start_xmit(struct sk_buff *skb, struct net_device *ndev)
{
	struct rl_priv *priv = netdev_priv(ndev);
	struct device *dma_dev = rl_dma_dev(priv->tx_chan);
	struct dma_async_tx_descriptor *desc;
	struct rl_tx_buf *buf;
	struct scatterlist sg;
	dma_cookie_t cookie;
	unsigned long flags;
	unsigned int len;
	dma_addr_t dma;

	if (!CIRC_SPACE(priv->tx_head, READ_ONCE(priv->tx_tail), RL_TX_RING)) {
		netif_stop_queue(ndev);
		return NETDEV_TX_BUSY;
	}

	if (skb->len > RL_TX_MAX_FRAME || skb_linearize(skb))
		goto drop;

	len = skb->len;
	dma = dma_map_single(dma_dev, skb->data, len, DMA_TO_DEVICE);
	if (dma_mapping_error(dma_dev, dma))
		goto drop;

	sg_init_table(&sg, 1);
	sg_dma_address(&sg) = dma;
	sg_dma_len(&sg) = len;

	desc = dmaengine_prep_slave_sg(priv->tx_chan, &sg, 1, DMA_MEM_TO_DEV,
				       DMA_PREP_INTERRUPT | DMA_CTRL_ACK);
	if (!desc)
		goto unmap_drop;
	desc->callback_result = rl_tx_complete;
	desc->callback_param = priv;

	spin_lock_irqsave(&priv->tx_lock, flags);
	buf = &priv->tx_ring[priv->tx_head % RL_TX_RING];
	buf->skb = skb;
	buf->dma = dma;
	buf->len = len;
	cookie = dmaengine_submit(desc);
	if (dma_submit_error(cookie)) {
		buf->skb = NULL;
		spin_unlock_irqrestore(&priv->tx_lock, flags);
		goto unmap_drop;
	}
	priv->tx_head++;
	if (!CIRC_SPACE(priv->tx_head, priv->tx_tail, RL_TX_RING))
		netif_stop_queue(ndev);
	spin_unlock_irqrestore(&priv->tx_lock, flags);

	skb_tx_timestamp(skb);
	dma_async_issue_pending(priv->tx_chan);
	return NETDEV_TX_OK;

unmap_drop:
	dma_unmap_single(dma_dev, dma, len, DMA_TO_DEVICE);
drop:
	u64_stats_update_begin(&priv->tx_syncp);
	priv->tx_dropped++;
	u64_stats_update_end(&priv->tx_syncp);
	dev_kfree_skb_any(skb);
	return NETDEV_TX_OK;
}

static void rl_tx_drain(struct rl_priv *priv)
{
	unsigned long timeout = jiffies + msecs_to_jiffies(RL_TX_DRAIN_MS);

	while (READ_ONCE(priv->tx_tail) != READ_ONCE(priv->tx_head)) {
		if (time_after(jiffies, timeout)) {
			/* e.g. the MAC clock is stopped (GT reset) and the PL FIFO is full */
			netdev_warn(priv->ndev, "TX ring did not drain (%u frames)\n",
				    priv->tx_head - priv->tx_tail);
			break;
		}
		usleep_range(1000, 2000);
	}
}

static void rl_tx_ring_stop(struct rl_priv *priv)
{
	struct device *dma_dev = rl_dma_dev(priv->tx_chan);

	dmaengine_terminate_sync(priv->tx_chan);

	spin_lock_bh(&priv->tx_lock);
	while (priv->tx_tail != priv->tx_head) {
		struct rl_tx_buf *buf = &priv->tx_ring[priv->tx_tail % RL_TX_RING];

		dma_unmap_single(dma_dev, buf->dma, buf->len, DMA_TO_DEVICE);
		dev_kfree_skb(buf->skb);
		buf->skb = NULL;
		priv->tx_tail++;
		priv->tx_dropped++;
	}
	priv->tx_head = 0;
	priv->tx_tail = 0;
	spin_unlock_bh(&priv->tx_lock);
}

/* -------------------------------------------------------------------------
 * Data path start / stop
 */

static void rl_release_dma(struct rl_priv *priv)
{
	dma_release_channel(priv->rx_chan);
	dma_release_channel(priv->tx_chan);
	priv->rx_chan = NULL;
	priv->tx_chan = NULL;
}

static int rl_request_dma(struct rl_priv *priv)
{
	struct device *dev = priv->dev;

	priv->tx_chan = dma_request_chan(dev, "tx");
	if (IS_ERR(priv->tx_chan))
		return dev_err_probe(dev, PTR_ERR(priv->tx_chan), "no TX DMA channel\n");
	priv->rx_chan = dma_request_chan(dev, "rx");
	if (IS_ERR(priv->rx_chan)) {
		dma_release_channel(priv->tx_chan);
		return dev_err_probe(dev, PTR_ERR(priv->rx_chan), "no RX DMA channel\n");
	}
	return 0;
}

/*
 * The channels are requested at open and released at stop rather than held for the lifetime of the
 * driver: the soft reset xilinx_dma issues from terminate_all resets both channels of the engine,
 * and xilinx_dma re-enables a channel's interrupts only in alloc_chan_resources (dma_request_chan).
 */
static int rl_open(struct net_device *ndev)
{
	struct rl_priv *priv = netdev_priv(ndev);
	int ret;

	ret = rl_request_dma(priv);
	if (ret)
		return ret;
	ret = rl_rx_ring_start(priv);
	if (ret) {
		rl_release_dma(priv);
		return ret;
	}

	netif_carrier_off(ndev);
	WRITE_ONCE(priv->link_poll, true);
	rl_link_update(priv);
	schedule_delayed_work(&priv->link_work, msecs_to_jiffies(RL_LINK_POLL_MS));
	netif_start_queue(ndev);
	return 0;
}

static int rl_stop(struct net_device *ndev)
{
	struct rl_priv *priv = netdev_priv(ndev);

	WRITE_ONCE(priv->link_poll, false);
	cancel_delayed_work_sync(&priv->link_work);
	netif_tx_disable(ndev);
	rl_tx_drain(priv);
	rl_tx_ring_stop(priv);
	rl_rx_ring_stop(priv);
	rl_release_dma(priv);
	netif_carrier_off(ndev);
	return 0;
}

static int rl_change_mtu(struct net_device *ndev, int new_mtu)
{
	/* RX buffers always hold the longest frame: nothing to re-arm */
	WRITE_ONCE(ndev->mtu, new_mtu);
	return 0;
}

static void rl_tx_timeout(struct net_device *ndev, unsigned int txqueue)
{
	struct rl_priv *priv = netdev_priv(ndev);

	netdev_warn(ndev, "TX timeout (ring head %u tail %u, always-on status 0x%05x)\n",
		    priv->tx_head, priv->tx_tail, aon_read(priv, AON_STATUS));
	u64_stats_update_begin(&priv->tx_syncp);
	priv->tx_errors++;
	u64_stats_update_end(&priv->tx_syncp);
}

static void rl_get_stats64(struct net_device *ndev, struct rtnl_link_stats64 *stats)
{
	struct rl_priv *priv = netdev_priv(ndev);
	unsigned int start;

	do {
		start = u64_stats_fetch_begin(&priv->tx_syncp);
		stats->tx_packets = priv->tx_packets;
		stats->tx_bytes = priv->tx_bytes;
		stats->tx_errors = priv->tx_errors;
		stats->tx_dropped = priv->tx_dropped;
	} while (u64_stats_fetch_retry(&priv->tx_syncp, start));

	do {
		start = u64_stats_fetch_begin(&priv->rx_syncp);
		stats->rx_packets = priv->rx_packets;
		stats->rx_bytes = priv->rx_bytes;
		stats->rx_errors = priv->rx_errors + priv->rx_length_errors;
		stats->rx_length_errors = priv->rx_length_errors;
		stats->rx_dropped = priv->rx_dropped;
	} while (u64_stats_fetch_retry(&priv->rx_syncp, start));
}

static const struct net_device_ops rl_netdev_ops = {
	.ndo_open		= rl_open,
	.ndo_stop		= rl_stop,
	.ndo_start_xmit		= rl_start_xmit,
	.ndo_set_mac_address	= eth_mac_addr,
	.ndo_validate_addr	= eth_validate_addr,
	.ndo_change_mtu		= rl_change_mtu,
	.ndo_tx_timeout		= rl_tx_timeout,
	.ndo_get_stats64	= rl_get_stats64,
};

/* -------------------------------------------------------------------------
 * ethtool
 */

static const char rl_stat_names[][ETH_GSTRING_LEN] = {
	"rx_copybreak",
	"rx_long",
	"rx_length_errors",
	"carrier_changes",
	"aon_link_up_events",
	"aon_link_down_events",
	"aon_mac_clock_khz",
};

static void rl_get_drvinfo(struct net_device *ndev, struct ethtool_drvinfo *info)
{
	struct rl_priv *priv = netdev_priv(ndev);

	strscpy(info->driver, RL_DRV_NAME, sizeof(info->driver));
	strscpy(info->version, RL_DRV_VERSION, sizeof(info->version));
	strscpy(info->bus_info, dev_name(priv->dev), sizeof(info->bus_info));
	snprintf(info->fw_version, sizeof(info->fw_version), "aon %u.%u",
		 aon_read(priv, AON_VERSION) >> 16, aon_read(priv, AON_VERSION) & 0xffff);
}

static int rl_get_link_ksettings(struct net_device *ndev, struct ethtool_link_ksettings *cmd)
{
	struct rl_priv *priv = netdev_priv(ndev);

	ethtool_link_ksettings_zero_link_mode(cmd, supported);
	ethtool_link_ksettings_zero_link_mode(cmd, advertising);
	ethtool_link_ksettings_add_link_mode(cmd, supported, FIBRE);
	switch (priv->gbps) {
	case 10:
		ethtool_link_ksettings_add_link_mode(cmd, supported, 10000baseCR_Full);
		break;
	case 25:
		ethtool_link_ksettings_add_link_mode(cmd, supported, 25000baseCR_Full);
		break;
	case 40:
		ethtool_link_ksettings_add_link_mode(cmd, supported, 40000baseCR4_Full);
		break;
	case 100:
		ethtool_link_ksettings_add_link_mode(cmd, supported, 100000baseCR4_Full);
		break;
	}
	cmd->base.speed = netif_carrier_ok(ndev) ? priv->gbps * 1000 : SPEED_UNKNOWN;
	cmd->base.duplex = netif_carrier_ok(ndev) ? DUPLEX_FULL : DUPLEX_UNKNOWN;
	cmd->base.port = PORT_DA;
	cmd->base.autoneg = AUTONEG_DISABLE;
	return 0;
}

static void rl_get_strings(struct net_device *ndev, u32 stringset, u8 *data)
{
	unsigned int i;

	if (stringset != ETH_SS_STATS)
		return;
	for (i = 0; i < ARRAY_SIZE(rl_stat_names); i++)
		ethtool_puts(&data, rl_stat_names[i]);
}

static int rl_get_sset_count(struct net_device *ndev, int sset)
{
	return sset == ETH_SS_STATS ? ARRAY_SIZE(rl_stat_names) : -EOPNOTSUPP;
}

static void rl_get_ethtool_stats(struct net_device *ndev, struct ethtool_stats *stats, u64 *data)
{
	struct rl_priv *priv = netdev_priv(ndev);
	u32 ev = aon_read(priv, AON_LINK_EV);
	unsigned int start, n = 0;

	do {
		start = u64_stats_fetch_begin(&priv->rx_syncp);
		data[0] = priv->rx_copybreak;
		data[1] = priv->rx_long;
		data[2] = priv->rx_length_errors;
	} while (u64_stats_fetch_retry(&priv->rx_syncp, start));
	n = 3;
	data[n++] = priv->carrier_changes;
	data[n++] = ev & 0xffff;
	data[n++] = ev >> 16;
	data[n++] = aon_read(priv, AON_MAC_KHZ);
}

static void rl_get_ringparam(struct net_device *ndev, struct ethtool_ringparam *ring,
			     struct kernel_ethtool_ringparam *kring,
			     struct netlink_ext_ack *extack)
{
	ring->rx_max_pending = RL_RX_RING;
	ring->tx_max_pending = RL_TX_RING;
	ring->rx_pending = RL_RX_RING;
	ring->tx_pending = RL_TX_RING;
}

static const struct ethtool_ops rl_ethtool_ops = {
	.get_drvinfo		= rl_get_drvinfo,
	.get_link		= ethtool_op_get_link,
	.get_link_ksettings	= rl_get_link_ksettings,
	.get_strings		= rl_get_strings,
	.get_sset_count		= rl_get_sset_count,
	.get_ethtool_stats	= rl_get_ethtool_stats,
	.get_ringparam		= rl_get_ringparam,
};

/* -------------------------------------------------------------------------
 * Probe / remove
 */

static void rl_check_irq_delay(struct rl_priv *priv)
{
	struct device_node *dma_np = rl_dma_dev(priv->rx_chan)->of_node;
	struct device_node *child;
	const u8 *prop;
	int len;

	if (!dma_np)
		return;
	for_each_child_of_node(dma_np, child) {
		if (!of_device_is_compatible(child, "xlnx,axi-dma-s2mm-channel"))
			continue;
		prop = of_get_property(child, "xlnx,irq-delay", &len);
		if (!prop || len != 1 || !*prop)
			dev_warn(priv->dev,
				 "%pOF: no 8-bit non-zero xlnx,irq-delay ('/bits/ 8 <1>'); receive latency will be poor\n",
				 child);
		of_node_put(child);
		return;
	}
	dev_warn(priv->dev, "no S2MM channel node under %pOF\n", dma_np);
}

static int rl_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct net_device *ndev;
	struct resource *res;
	struct rl_priv *priv;
	u32 id, caps, ver;
	int ret;

	ndev = devm_alloc_etherdev(dev, sizeof(*priv));
	if (!ndev)
		return -ENOMEM;
	SET_NETDEV_DEV(ndev, dev);
	platform_set_drvdata(pdev, ndev);

	priv = netdev_priv(ndev);
	priv->ndev = ndev;
	priv->dev = dev;
	spin_lock_init(&priv->tx_lock);
	spin_lock_init(&priv->rx_lock);
	init_llist_head(&priv->rx_done);
	u64_stats_init(&priv->tx_syncp);
	u64_stats_init(&priv->rx_syncp);
	INIT_DELAYED_WORK(&priv->link_work, rl_link_work);

	/* The always-on block sits inside the register window roceletd maps through UIO: map it
	 * without claiming the region (read-only use here). */
	res = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!res)
		return dev_err_probe(dev, -EINVAL, "no reg\n");
	priv->aon = devm_ioremap(dev, res->start, resource_size(res));
	if (!priv->aon)
		return -ENOMEM;

	id = aon_read(priv, AON_ID);
	if (id != AON_ID_MAGIC)
		return dev_err_probe(dev, -ENODEV, "always-on block not found (ID 0x%08x)\n", id);
	caps = aon_read(priv, AON_CAPS);
	ver = aon_read(priv, AON_VERSION);
	if (!(caps & AON_CAPS_NETDEV_DMA))
		return dev_err_probe(dev, -ENODEV, "design built without the netdev DMA channel (caps 0x%08x)\n",
				     caps);
	priv->gbps = FIELD_GET(AON_CAPS_GBPS, caps);

	ret = rl_request_dma(priv);
	if (ret)
		return ret;
	rl_check_irq_delay(priv);
	rl_release_dma(priv);

	ret = of_get_ethdev_address(dev->of_node, ndev);
	if (ret) {
		eth_hw_addr_random(ndev);
		dev_info(dev, "no local-mac-address: random MAC %pM\n", ndev->dev_addr);
	}

	ndev->netdev_ops = &rl_netdev_ops;
	ndev->ethtool_ops = &rl_ethtool_ops;
	netif_napi_add(ndev, &priv->napi, rl_rx_poll);
	ndev->min_mtu = ETH_MIN_MTU;
	ndev->max_mtu = RL_MAX_MTU;
	ndev->watchdog_timeo = 5 * HZ;
	/* roceletd keeps rl0's MAC and the engine's equal: the console's 'mac' changes it while up */
	ndev->priv_flags |= IFF_LIVE_ADDR_CHANGE;
	netif_carrier_off(ndev);

	/* the interface name the documentation and roceletd use */
	strscpy(ndev->name, "rl%d", IFNAMSIZ);
	ret = register_netdev(ndev);
	if (ret)
		return dev_err_probe(dev, ret, "failed to register the netdev\n");

	netdev_info(ndev, "rocelet port 0 (always-on block v%u.%u, %u Gb/s), MAC %pM\n", ver >> 16,
		    ver & 0xffff, priv->gbps, ndev->dev_addr);
	return 0;
}

static void rl_remove(struct platform_device *pdev)
{
	struct net_device *ndev = platform_get_drvdata(pdev);

	unregister_netdev(ndev);
}

static const struct of_device_id rl_of_match[] = {
	{ .compatible = "opsero,rocelet-net-1.0" },
	{ }
};
MODULE_DEVICE_TABLE(of, rl_of_match);

static struct platform_driver rl_driver = {
	.probe	= rl_probe,
	.remove	= rl_remove,
	.driver	= {
		.name		= RL_DRV_NAME,
		.of_match_table	= rl_of_match,
	},
};
module_platform_driver(rl_driver);

MODULE_AUTHOR("Opsero Electronic Design Inc.");
MODULE_DESCRIPTION("qsfp28-fmc-rocelet network interface (rl0) over the netdev DMA channel");
MODULE_VERSION(RL_DRV_VERSION);
MODULE_LICENSE("Dual MIT/GPL");
