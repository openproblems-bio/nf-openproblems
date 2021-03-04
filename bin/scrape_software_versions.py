#!/usr/bin/env python
from __future__ import print_function
from collections import OrderedDict
import re

# TODO nf-core: Add additional regexes for new tools in process get_software_versions
regexes = {
    "nf-openproblems": ["v_pipeline.txt", r"(\S+)"],
    "Nextflow": ["v_nextflow.txt", r"(\S+)"],
    "Python": ["v_python.txt", r"Python (\S+)"],
    "openproblems": ['v_openproblems.txt', r"(\S+)"]
}
results = OrderedDict()
# Search each file using its regex
for k, v in regexes.items():
    results[k] = '<span style="color:#999999;">N/A</span>'
    try:
        with open(v[0]) as x:
            versions = x.read()
            match = re.search(v[1], versions)
            if match:
                results[k] = "v{}".format(match.group(1))
    except IOError:
        pass

# Dump to YAML
print(
    """
id: 'software_versions'
section_name: 'singlecellopenproblems/nf-openproblems Software Versions'
section_href: 'https://github.com/singlecellopenproblems/nf-openproblems'
plot_type: 'html'
description: 'are collected at run time from the software output.'
data: |
    <dl class="dl-horizontal">
"""
)
for k, v in results.items():
    print("        <dt>{}</dt><dd><samp>{}</samp></dd>".format(k, v))
print("    </dl>")

# Write out regexes as csv file:
with open("software_versions.csv", "w") as f:
    for k, v in results.items():
        f.write("{}\t{}\n".format(k, v))
