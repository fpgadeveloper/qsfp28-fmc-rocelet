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

Usage (from this directory):  python3 update.py
'''

import os
import json

HERE = os.path.dirname(os.path.abspath(__file__))

def rel(path):
    return os.path.normpath(os.path.join(HERE, path))

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
        tables.append('| Target board          | Target design      | Ports       | FEC         | FMC Slot(s) | Standalone<br> console | Built-in<br> self-test | Vivado<br> Edition |')
        tables.append('|-----------------------|--------------------|-------------|-------------|-------------|-------|-------|-------|')
        for design in data['designs']:
            if not design['publish']:
                continue
            if design['group'] == group['label']:
                cols = []
                cols.append('[{0}]'.format(design['board']).ljust(21))
                cols.append('`{0}`'.format(design['label']).ljust(18))
                ports = '{}x 100G'.format(design['ports'])
                cols.append('{0}'.format(ports).ljust(11))
                cols.append('{0}'.format(to_fec[design.get('fec', 'none')]).ljust(11))
                cols.append('{0}'.format(design['connector']).ljust(11))
                cols.append('{0}'.format(to_emoji[design['baremetal']]).ljust(5))
                cols.append('{0}'.format(to_emoji[design.get('selftest', False)]).ljust(5))
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
#   dict set target_dict <label> { <url> <boardname> <bdscript> <port> <fec> <selftest> { <engine parameters> } }
# build.tcl uses <bdscript> to pick src/bd/bd_<bdscript>.tcl and passes the
# QSFP28 port (the first entry of "lanes"), the FEC mode ("rs" or "none"), the
# self-test option (1 = include the pattern source/sink, checkers and fault
# injectors) and the rocelet_sys parameters: the engine's ("engine": {NAME:
# value}) and the memory window size ("mem_bytes" -> MEM_BYTES) to it.
def get_vivado_build_targets(data):
    targets = []
    for design in data['designs']:
        port = design.get('lanes', [0])[0]
        params = dict(design.get('engine', {}))
        if 'mem_bytes' in design:
            params['MEM_BYTES'] = design['mem_bytes']
        eng = ' '.join('{} {}'.format(k, v) for k, v in params.items())
        target = 'dict set target_dict {} {{ {} {} {} {} {} {} {{ {} }} }}'.format(
            design['label'], design['url'], design['boardname'], design['bdscript'], port,
            design.get('fec', 'none'), 1 if design.get('selftest', False) else 0, eng)
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
    # Read the JSON data
    data = load_json(rel('data.json'))

    # Update the main README.md file
    update_readme(rel('../README.md'),data)

    # Update the Vivado build.tcl
    update_file(rel('../Vivado/scripts/build.tcl'),get_vivado_build_targets(data))

    # Update the gitignore
    update_file(rel('../.gitignore'),get_ignore_paths(data))

    # Check that the sources every target needs exist
    check_sources(data)
