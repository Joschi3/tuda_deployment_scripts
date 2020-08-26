#!/usr/bin/env python
from catkin_tools import context
from argparse import ArgumentParser

def get_blacklisted_packages(workspace_hint=None, profile=None):
  ctx = context.Context.load(workspace_hint=workspace_hint, profile=profile, strict=True)
  return ctx.blacklist

if __name__ == "__main__":
  parser = ArgumentParser()
  parser.add_argument("--workspace", metavar="PATH")
  parser.add_argument("--profile")
  args = parser.parse_args()
  print("\n".join(get_blacklisted_packages(args.workspace, args.profile)))
