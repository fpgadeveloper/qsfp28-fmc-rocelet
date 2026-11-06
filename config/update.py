'''
Opsero Electronic Design Inc.

data.json is intended to be a centralized source of information regarding all of the target
designs and it ensures that the documentation and build scripts are consistent.
When data.json is updated with new information, this Python script can be run to update
the main README.md file of the repo, the Vivado build script and the .gitignore. We typically
use this script when adding/removing target designs.

The build runner (build.py) reads data.json directly at runtime, so this script only
regenerates the content that is *not* read at runtime:

  ../README.md                  target design tables  (<!-- updater start/end --> markers)
  ../Vivado/scripts/build.tcl   target_dict           (# UPDATER START/END markers)
  ../.gitignore                 per-target build output directories (# UPDATER START/END)

The Sphinx documentation also refers to the data.json file when compiling the target design
and supported board tables.

Usage (from the repository root):  python3 config/update.py

MAC options. A target whose entry lists "mac_options" can be built with any of those MACs
under the same label (zcu106: omac_40g = the shipping 40GBASE-R4 configuration, omac_10g =
the 10GBASE-R option). The MAC is the target's "mac" attribute; the attributes that follow
from it (link_gbps, mac_width, linkspeed, lanes) are set together from the MAC table below:

  python3 config/update.py --mac zcu106=omac_10g     # the 10G option: data.json rewritten + regenerated
  python3 config/update.py --mac zcu106=omac_40g     # back to the shipping configuration

then build as usual (./build.sh all --target zcu106). Only the Vivado / Vitis / Yocto outputs of
that label change; a Vivado project of the other MAC is rebuilt from scratch.
'''

import os
import sys
import json
import argparse

HERE = os.path.dirname(os.path.abspath(__file__))

def rel(path):
    return os.path.normpath(os.path.join(HERE, path))

# MAC table: the attributes of a target that follow from its MAC ("mac"), for --mac
MAC_ATTRS = {
    "cmac":     {"link_gbps": 100, "mac_width": 512, "linkspeed": "100", "lanes": [0]},
    "omac_10g": {"link_gbps": 10,  "mac_width": 64,  "linkspeed": "10",  "lanes": [0]},
    "omac_40g": {"link_gbps": 40,  "mac_width": 256, "linkspeed": "40",  "lanes": [0]},
}

# --mac <label>=<mac>: select one of a target's "mac_options" in data.json
def select_mac(data, spec):
    if '=' not in spec:
        sys.exit("ERROR: --mac expects <label>=<mac>, e.g. zcu106=omac_10g")
    label, mac = spec.split('=', 1)
    for design in data['designs']:
        if design['label'] != label:
            continue
        opts = design.get('mac_options', [design.get('mac', 'cmac')])
        if mac not in opts:
            sys.exit("ERROR: target {} has the MAC options {}, not {}".format(label, ', '.join(opts), mac))
        design['mac'] = mac
        design.update(MAC_ATTRS[mac])
        print("{}: MAC {} ({} Gb/s, MAC_WIDTH {})".format(label, mac, design['link_gbps'], design['mac_width']))
        return True
    sys.exit("ERROR: no target {} in data.json".format(label))

# Load the JSON data
def load_json(filename):
    with open(filename) as f:
        return json.load(f)

# Create design tables for the README.md file
# This function determines the formatting of the design tables
def create_tables(data):
    # Emoji dict
    to_emoji = {True: ":white_check_mark:", False: ":x:"}
    # License dict
    to_edition = {True: "Enterprise", False: "Standard :free:"}
    # FEC dict (data.json "fec")
    to_fec = {"rs": "RS-FEC (CL91)", "none": "None"}
    # Determine which groups actually have designs
    used_groups = []
    for group in data['groups']:
        for design in data['designs']:
            if not design['publish']:
                continue
            if design['group'] == group['label']:
                used_groups.append(group)
                break
    # Print tables for each used group
    tables = []
    links = {}
    for group in used_groups:
        tables.append('### {} designs'.format(group['name']))
        tables.append('')
        tables.append('| Target board          | Target design      | Ports       | FEC         | FMC Slot(s) | Standalone<br> console | Linux<br> (Yocto) | Vivado<br> Edition |')
        tables.append('|-----------------------|--------------------|-------------|-------------|-------------|-------|-------|-------|')
        for design in data['designs']:
            if not design['publish']:
                continue
            if design['group'] == group['label']:
                cols = []
                cols.append('[{0}]'.format(design['board']).ljust(21))
                cols.append('`{0}`'.format(design['label']).ljust(18))
                ports = '{}x {}G'.format(design['ports'], design.get('linkspeed', '100'))
                others = [m for m in design.get('mac_options', []) if m != design.get('mac')]
                if others:
                    ports += ' ({} option)'.format(', '.join('{}G'.format(MAC_ATTRS[m]['link_gbps']) for m in others))
                cols.append('{0}'.format(ports).ljust(11))
                cols.append('{0}'.format(to_fec[design.get('fec', 'none')]).ljust(11))
                cols.append('{0}'.format(design['connector']).ljust(11))
                cols.append('{0}'.format(to_emoji[design['baremetal']]).ljust(5))
                cols.append('{0}'.format(to_emoji[design.get('yocto', False)]).ljust(5))
                cols.append('{0}'.format(to_edition[design['license']]).ljust(5))
                tables.append('| ' + ' | '.join(cols) + ' |')
                links[design['board']] = design['link']
        tables.append('')
    # Add the board links
    for k,v in links.items():
        tables.append('[{0}]: {1}'.format(k,v))
    return(tables)

# Update the README.md file target design tables
def update_readme(file_path,data):
    # Create the tables from the data
    tables = create_tables(data)
    # Read the content of the file
    with open(file_path, 'r') as infile:
        lines = infile.readlines()

    # Open the same file in write mode to overwrite it
    with open(file_path, 'w') as outfile:
        inside_updater = False

        for line in lines:
            if '<!-- updater start -->' in line:
                # Write the start tag to the file
                outfile.write(line)
                # Write the tables
                for l in tables:
                    outfile.write("{}\n".format(l))
                inside_updater = True
            elif '<!-- updater end -->' in line:
                # Write the end tag to the file
                outfile.write(line)
                inside_updater = False
            elif not inside_updater:
                # Write the line if not inside the updater block
                outfile.write(line)

# One line per target for Vivado/scripts/build.tcl:
#   dict set target_dict <label> { <url> <boardname> <bdscript> <port> <fec> <selftest> { <rocelet_sys parameters> } <mac> { <GT placement> } }
# build.tcl uses <bdscript> to pick src/bd/bd_<bdscript>.tcl and passes the
# QSFP28 port (the first entry of "lanes"), the FEC mode ("rs" or "none"), the
# self-test option (1 = include the pattern source/sink, checkers and fault
# injectors) and the rocelet_sys parameters: the engine's ("engine": {NAME:
# value}), the memory window size ("mem_bytes" -> MEM_BYTES), the MAC side
# ("mac_width" -> MAC_WIDTH, "clk_khz" -> CLK_KHZ and CLK_MHZ, "clk_hz" -> CLK_HZ,
# "link_gbps" -> LINK_GBPS) and the ZynqMP options ("ddr_window" -> DDR_EN,
# "ddr_ports" -> DDR_PORTS: 1 or 2 HP ports per direction, "netdev_dma" -> ODMA_EN) to it, plus the MAC type ("mac": cmac | omac_10g | omac_40g), which
# selects the MAC adapter sources (Vivado/src/hdl/mac) and, for omac, the MAC IP.
# The GT placement of the QSFP28 port ({ channels {..} refclk clkN } or { channels {..}
# cmac_core CMACE4_XnYm }) comes from "gt_channels" (the transceiver channel sites in QSFP
# lane order 0-3, e.g. X0Y14: omac_10g uses lane 0, omac_40g and cmac all four of one quad),
# "gt_refclk" (omac: the reference clock of the lane 0 channel as the gtwizard IP names it,
# clk0 / clk1 = MGTREFCLK0 / 1 of its quad, clk0+1 / clk0-1 ... = one of the quad above /
# below) and "cmac_core" (cmac: the CMAC hard block site); build.tcl checks them.
def gt_placement(design):
    mac = design.get('mac', 'cmac')
    chans = design.get('gt_channels', [])
    need = 1 if mac == 'omac_10g' else 4
    if len(chans) < need or (need == 4 and len(chans) != 4):
        sys.exit("ERROR: target {} (mac {}) needs {} gt_channels in data.json, has {}".format(
            design['label'], mac, 'four' if need == 4 else 'at least one', len(chans)))
    gt = 'channels {{{}}}'.format(' '.join(chans))
    if mac == 'cmac':
        if 'cmac_core' not in design:
            sys.exit("ERROR: target {} (mac cmac) needs cmac_core in data.json".format(design['label']))
        gt += ' cmac_core {}'.format(design['cmac_core'])
    else:
        gt += ' refclk {}'.format(design.get('gt_refclk', 'clk0'))
    return gt

def get_vivado_build_targets(data):
    targets = []
    for design in data['designs']:
        port = design.get('lanes', [0])[0]
        params = dict(design.get('engine', {}))
        if 'mem_bytes' in design:
            params['MEM_BYTES'] = design['mem_bytes']
        if 'mac_width' in design:
            params['MAC_WIDTH'] = design['mac_width']
        if 'clk_khz' in design:
            params['CLK_MHZ'] = int(round(design['clk_khz'] / 1000.0))
            params['CLK_KHZ'] = design['clk_khz']
            params['CLK_HZ'] = design.get('clk_hz', design['clk_khz'] * 1000)
        if 'link_gbps' in design:
            params['LINK_GBPS'] = design['link_gbps']
        if design.get('ddr_window', False):
            params['DDR_EN'] = 1
        if design.get('ddr_window', False) and 'ddr_ports' in design:
            params['DDR_PORTS'] = design['ddr_ports']
        if design.get('netdev_dma', False):
            params['ODMA_EN'] = 1
        eng = ' '.join('{} {}'.format(k, v) for k, v in params.items())
        target = 'dict set target_dict {} {{ {} {} {} {} {} {} {{ {} }} {} {{ {} }} }}'.format(
            design['label'], design['url'], design['boardname'], design['bdscript'], port,
            design.get('fec', 'none'), 1 if design.get('selftest', False) else 0, eng,
            design.get('mac', 'cmac'), gt_placement(design))
        targets.append(target)
    return(targets)

# Per-target build output directories for the root .gitignore. The Vivado
# project of every target and the Yocto workspace of every Yocto target live
# at Vivado/<label>/ and Yocto/<label>/ (Yocto/.gitignore ignores them too;
# this keeps the root file self-contained). Vitis workspaces are covered by
# the fixed Vitis/*_workspace/ pattern.
def get_ignore_paths(data):
    paths = []
    for design in data['designs']:
        paths.append('Vivado/{}/'.format(design['label']))
        if design.get('yocto', False):
            paths.append('Yocto/{}/'.format(design['label']))
    return(paths)

# Update a file that uses "# UPDATER START" and "# UPDATER END" tags
def update_file(file_path,targets):
    # Read the content of the file
    with open(file_path, 'r') as infile:
        lines = infile.readlines()

    # Open the same file in write mode to overwrite it
    with open(file_path, 'w') as outfile:
        inside_updater = False

        for line in lines:
            if '# UPDATER START' in line:
                # Write the start tag to the file
                outfile.write(line)
                # Write the targets
                for l in targets:
                    outfile.write("{}\n".format(l))
                inside_updater = True
            elif '# UPDATER END' in line:
                # Write the end tag to the file
                outfile.write(line)
                inside_updater = False
            elif not inside_updater:
                # Write the line if not inside the updater block
                outfile.write(line)

# Make sure that there is a constraints file and a block design script for all
# target designs, and a Yocto board BSP for every Yocto target
def check_sources(data):
    for design in data['designs']:
        filename = rel('../Vivado/src/constraints/{}.xdc'.format(design['label']))
        if not os.path.isfile(filename):
            print('WARNING: No constraints file found for target',design['label'])
        filename = rel('../Vivado/src/bd/bd_{}.tcl'.format(design['bdscript']))
        if not os.path.isfile(filename):
            print('WARNING: No block design script bd_{}.tcl found for target'.format(design['bdscript']),design['label'])
        if design.get('yocto', False):
            board = design['label'].split('_')[0]
            dirname = rel('../Yocto/bsp/{}'.format(board))
            if not os.path.isdir(dirname):
                print('WARNING: No Yocto BSP found at Yocto/bsp/{} for target'.format(board),design['label'])
            portcfg = design.get('portcfg')
            if portcfg and not os.path.isdir(rel('../Yocto/bsp/port-configs/{}'.format(portcfg))):
                print('WARNING: No Yocto port-config overlay found at Yocto/bsp/port-configs/{} for target'.format(portcfg),design['label'])

if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='Regenerate README tables, build.tcl targets and .gitignore from data.json')
    ap.add_argument('--mac', action='append', default=[], metavar='LABEL=MAC',
                    help="select one of a target's mac_options (rewrites data.json), e.g. zcu106=omac_10g")
    args = ap.parse_args()
    # Read the JSON data
    data = load_json(rel('data.json'))
    if args.mac:
        for spec in args.mac:
            select_mac(data, spec)
        with open(rel('data.json'), 'w') as f:
            f.write(json.dumps(data, indent=2) + '\n')

    # Update the main README.md file
    update_readme(rel('../README.md'),data)

    # Update the Vivado build.tcl
    update_file(rel('../Vivado/scripts/build.tcl'),get_vivado_build_targets(data))

    # Update the gitignore
    update_file(rel('../.gitignore'),get_ignore_paths(data))

    # Check that the sources every target needs exist
    check_sources(data)
