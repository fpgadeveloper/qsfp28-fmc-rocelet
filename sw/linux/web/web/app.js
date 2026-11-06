// SPDX-License-Identifier: MIT  Copyright (c) 2026 Opsero Electronic Design Inc.
"use strict";
const $ = (id) => document.getElementById(id);
let token = "";
try { token = localStorage.getItem("rocelet_token") || ""; } catch (e) { /* no storage */ }
let prev = null, prevT = 0, busy = false;

function hdrs() { return token ? { "X-Rocelet-Token": token } : {}; }

async function api(path, body) {
  const opt = body === undefined ? { headers: hdrs() } :
    { method: "POST", headers: Object.assign({ "Content-Type": "application/json" }, hdrs()), body: JSON.stringify(body) };
  const r = await fetch(path, opt);
  if (r.status === 403) { $("tokenbox").hidden = false; throw new Error("token required"); }
  return r.json();
}

function fmtNum(v) { return v === undefined || v === null ? "-" : Number(v).toLocaleString(); }
function gbps(bytes, s) { return s > 0 ? (bytes * 8 / s / 1e9).toFixed(2) + " Gb/s" : "-"; }

function render(s) {
  const st = $("state");
  st.textContent = s.link_up ? "link up" : "link down";
  st.className = "pill " + (s.link_up ? "ok" : "bad");
  $("t_link").innerHTML = `<span class="${s.link_up ? "up" : "down"}">${s.link_up ? "UP" : "DOWN"}</span> ${s.link_gbps} Gb/s`;
  $("t_link2").textContent = `${s.mac_name}, MAC clock ${s.aon ? (s.aon.mac_khz / 1000).toFixed(2) : "-"} MHz, loopback ${s.loopback}` +
    `, QSFP ${s.aon && s.aon.qsfp_present ? "present" : "absent"}, link events ${s.aon ? s.aon.link_up_events + "/" + s.aon.link_down_events : "-"}`;
  const n = s.netdev || {};
  $("t_net").innerHTML = n.present ? `<span class="${n.carrier ? "up" : "down"}">${n.up ? (n.carrier ? "up" : "no carrier") : "down"}</span> ${n.ip}` : "absent";
  $("t_net2").textContent = n.present ? `${n.name} ${n.mac}, rx ${fmtNum(n.rx_packets)} tx ${fmtNum(n.tx_packets)} frames` : "rl_net.ko not loaded";
  $("t_eng").textContent = s.engine ? `rocelet ${(s.engine.version >> 16) & 255}.${(s.engine.version >> 8) & 255}.${s.engine.version & 255}` : (s.mac_clock ? "not found" : "MAC clock stopped");
  $("t_eng2").textContent = `${s.fpga_ip} ${s.fpga_mac}, ${s.netdev_mode ? "ARP/ICMP by Linux" : "ARP/ICMP by the engine"}${s.paused ? " (test running)" : ""}${s.engine && s.engine.err ? ", ERROR latched" : ""}`;
  $("t_hsb").textContent = s.hsb_on ? "on" : "off";
  $("t_hsb2").textContent = "Holoscan Sensor Bridge device mode ('hsb st' below)";
  const now = performance.now() / 1000;
  if (s.engine) {
    let rx = "-", tx = "";
    if (prev && prev.engine && now > prevT) {
      const dt = now - prevT;
      rx = gbps(s.engine.rx_bytes - prev.engine.rx_bytes, dt);
      tx = gbps(s.engine.tx_bytes - prev.engine.tx_bytes, dt);
    }
    $("t_rate").textContent = `rx ${rx}`;
    $("t_rate2").textContent = `tx ${tx || "-"} (engine, wire bytes)`;
  }
  // counters
  const rows = [];
  const add = (name, v, pv) => rows.push([name, v, pv]);
  const dt = prev ? now - prevT : 0;
  const rate = (a, b) => (dt > 0 && b !== undefined) ? Math.max(0, (a - b) / dt) : null;
  if (s.mac_counters) for (const [k, v] of Object.entries(s.mac_counters)) add("mac " + k, v, prev && prev.mac_counters ? rate(v, prev.mac_counters[k]) : null);
  if (s.odma) for (const [k, v] of Object.entries(s.odma)) add("netdev channel " + k, v, prev && prev.odma ? rate(v, prev.odma[k]) : null);
  if (s.ddr) add("PS DDR window bursts wr / rd / outside", `${fmtNum(s.ddr.wr_bursts)} / ${fmtNum(s.ddr.rd_bursts)} / ${fmtNum(s.ddr.outside)}`, null);
  if (s.engine) for (const [k, v] of Object.entries(s.engine.counters)) add("engine " + k, v, prev && prev.engine ? rate(v, prev.engine.counters[k] || 0) : null);
  $("counters").tBodies[0].innerHTML = rows.map(([k, v, r]) =>
    `<tr><td>${k}</td><td>${typeof v === "number" ? fmtNum(v) : v}</td><td>${r === null ? "" : fmtNum(Math.round(r))}</td></tr>`).join("");
  // QPs
  if (s.qp) $("qps").innerHTML = s.qp.map((q, i) =>
    `<span class="qp ${q & 6 ? "e" : (q & 1 ? "v" : "")}" title="status 0x${q.toString(16)}">QP ${i}${q & 6 ? " error" : (q & 1 ? "" : " off")}</span>`).join("");
  prev = s; prevT = now;
}

async function poll() {
  if (!busy) {
    try {
      const s = await api("/api/status");
      if (s.error) { $("state").textContent = s.busy ? "busy" : "daemon?"; $("state").className = "pill"; }
      else render(s);
    } catch (e) { $("state").textContent = "offline"; $("state").className = "pill bad"; }
  }
  setTimeout(poll, 1000);
}

function show(text) { $("out").textContent = text; }

async function run(line) {
  busy = true;
  show(`rl> ${line}\n(running...)`);
  try {
    const r = await api("/api/cmd", { line });
    show(`rl> ${line}\n${r.out || r.error || ""}${r.rc ? `\n(exit status ${r.rc})` : ""}`);
    return r;
  } catch (e) { show(String(e)); } finally { busy = false; }
}

async function text(name) {
  try { const r = await api("/api/text?cmd=" + encodeURIComponent(name)); show(r.out || r.error || ""); }
  catch (e) { show(String(e)); }
}

document.querySelectorAll("[data-cmd]").forEach((b) => b.addEventListener("click", () => run(b.dataset.cmd)));
document.querySelectorAll("[data-text]").forEach((b) => b.addEventListener("click", () => text(b.dataset.text)));
$("selftest").addEventListener("click", async () => {
  $("t_test").textContent = "running";
  const r = await run("t pma");
  const m = r && r.out ? r.out.match(/SELFTEST (PASS|FAIL) [^\n]*/) : null;
  $("t_test").innerHTML = m ? `<span class="${m[1] === "PASS" ? "up" : "down"}">${m[1]}</span>` : "?";
  $("t_test2").textContent = m ? m[0] : "";
});
$("qpshow").addEventListener("click", () => text("qp" + $("qpn").value));
$("rlhsend").addEventListener("click", () => {
  const lines = $("rlh").value.split("\n").map((l) => l.trim()).filter((l) => /\bRLHM?\b/.test(l));
  if (lines.length) run(lines.join("\n"));
});
$("hsbsrcset").addEventListener("click", () => run("hsb src " + $("hsbsrc").value));
$("hsbrateset").addEventListener("click", () => run("hsb rate " + $("hsbrate").value));
$("hsbsceneset").addEventListener("click", () => run("hsb scene " + $("hsbscene").value));
$("cmdrun").addEventListener("click", () => { if ($("cmdline").value.trim()) run($("cmdline").value.trim()); });
$("cmdline").addEventListener("keydown", (e) => { if (e.key === "Enter") $("cmdrun").click(); });
$("tokenset").addEventListener("click", () => {
  token = $("token").value;
  try { localStorage.setItem("rocelet_token", token); } catch (e) { /* no storage */ }
  document.cookie = "rocelet_token=" + encodeURIComponent(token) + "; path=/";
  $("tokenbox").hidden = true;
});

api("/api/info").then((i) => {
  if (i.title) { $("title").textContent = i.title; document.title = i.title + " - rocelet"; }
  $("warn").hidden = !!i.token;
}).catch(() => {});
poll();
text("st");
