#!/usr/bin/env python3
"""List open issues as a nested tree built from GitHub's native sub-issue links.

Hierarchy comes from each issue's formal `parent` (sub-issue) relationship, not from
`#number` text mentions. Issues whose parent is closed (or otherwise not open) surface as
top-level roots. Within each level, items sort by priority label then issue number.
"""

import json
import subprocess
import sys

OWNER = "jpease"
REPO = "hex-outdated.nvim"


def run_gh_command(args):
    result = subprocess.run(["gh"] + args, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"Error running gh command: {result.stderr}", file=sys.stderr)
        return None
    return result.stdout


def get_issues():
    query = """
    query($cursor: String) {
      repository(owner: "%s", name: "%s") {
        issues(first: 100, after: $cursor, states: OPEN) {
          pageInfo { hasNextPage endCursor }
          nodes {
            number
            title
            labels(first: 20) { nodes { name } }
            parent { number }
          }
        }
      }
    }
    """ % (OWNER, REPO)

    nodes = []
    cursor = None
    while True:
        args = ["api", "graphql", "-f", f"query={query}"]
        if cursor:
            args += ["-f", f"cursor={cursor}"]
        stdout = run_gh_command(args)
        if not stdout:
            break
        page = json.loads(stdout)["data"]["repository"]["issues"]
        nodes.extend(page["nodes"])
        if not page["pageInfo"]["hasNextPage"]:
            break
        cursor = page["pageInfo"]["endCursor"]
    return nodes


def get_priority(issue):
    for label in issue["labels"]["nodes"]:
        name = label["name"]
        if name.startswith("priority:P"):
            try:
                return int(name[len("priority:P") :])
            except ValueError:
                pass
    return 99


def main():
    issues = get_issues()
    if not issues:
        return

    issue_map = {issue["number"]: issue for issue in issues}

    children = {num: [] for num in issue_map}
    for issue in issues:
        parent = issue.get("parent")
        parent_num = parent["number"] if parent else None
        if parent_num in issue_map:
            children[parent_num].append(issue["number"])
        else:
            children.setdefault(None, []).append(issue["number"])

    roots = children.get(None, [])

    def sort_nums(nums):
        return sorted(nums, key=lambda n: (get_priority(issue_map[n]), n))

    def render(num, depth):
        issue = issue_map[num]
        priority = get_priority(issue)
        p_str = f"P{priority}" if priority < 99 else "---"
        indent = "  " * depth
        print(f"{indent}[{p_str}] #{num} - {issue['title']}")
        for child in sort_nums(children.get(num, [])):
            render(child, depth + 1)

    for root in sort_nums(roots):
        render(root, 0)


if __name__ == "__main__":
    main()
