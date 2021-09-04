#! /usr/bin/env python3

# Script used to search a bunch SVD files for a specific node
# Useful, eg., to check whether a specific SVD feature is actually used in the wild.
# Uses python and lxml for its xpath support

# For a large collection of SVD files, see https://github.com/posborne/cmsis-svd/tree/master/data

import os

from pathlib import Path

import argparse

from lxml import etree

def searchfile(fname, xpath):
  root = etree.parse(fname)

  for elem in root.xpath(xpath):
    try:
      srcline = elem.sourceline
    except AttributeError :
      srcline = elem.getparent().sourceline
    print(f"{fname}:({srcline})")

def main():
  parser = argparse.ArgumentParser(description="Search multiple SVD files for XPATH")
  parser.add_argument('xpath_expr', help="XPath expresssion to search for")
  parser.add_argument('path', type=Path, help="file or folder path")
  parser.add_argument('-g', "--glob", type=str, default="*.xml", help="Glob to filter files (use ** to recurse)")

  args = parser.parse_args()

  if not args.path.exists():
    print("Path does not exist: ", args.path)

  if args.path.is_file():
    searchfile(str(args.path), args.xpath_expr)
  elif args.path.is_dir():
    for p in args.path.glob(args.glob):
      searchfile(str(p), args.xpath_expr)

if __name__ == "__main__":
  main()
