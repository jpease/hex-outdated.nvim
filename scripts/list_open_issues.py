#!/usr/bin/env python3
"""List open issues as a nested tree built from parent/child relationships.

Hierarchy comes from three sources, in priority order:
  Pass 0: native GitHub sub-issue links (`issue.parent`) — authoritative.
  Pass 1: a "Parent epic: #N" line in the issue body (legacy/manual).
  Pass 2: `#N` references inside an epic's own body or comments, for repos (like
          this one) that track children via an "Ordered Checklist" instead of
          native sub-issue links.

Issues whose parent is closed (or otherwise not in the open set) surface as
top-level roots. Root epics sort by their bare `[x/y]` title prefix (see
`.claude/skills/issue-prefix-labels`); tasks under an epic sort by their
`[X:x/y]` prefix when present, otherwise by priority label then issue number.
"""

import json
import re
import subprocess
import sys
from collections import defaultdict

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
            body
            labels(first: 20) { nodes { name } }
            parent { number }
            comments(first: 100) { nodes { body } }
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


def is_epic(issue):
    return "Epic:" in (issue.get("title") or "")


def task_order_tag(issue):
    """Parse the `x` out of a task's `[X:x/y]` title prefix (model letter present)."""
    match = re.match(r"\s*\[[A-Za-z]+:(\d+)/\d+\]", issue.get("title", "") or "")
    return int(match.group(1)) if match else None


def epic_axis_tag(issue):
    """Parse the `x` out of a top-level epic's bare `[x/y]` title prefix."""
    match = re.match(r"\s*\[(\d+)/\d+\]", issue.get("title", "") or "")
    return int(match.group(1)) if match else None


def build_hierarchy(issues, issue_map):
    children = defaultdict(list)  # parent_num -> [child_num, ...]
    child_of = {}  # child_num -> parent_num

    # Pass 0: native sub-issue relationships take precedence over body text.
    for issue in issues:
        num = issue["number"]
        parent_obj = issue.get("parent")
        if parent_obj:
            parent = parent_obj["number"]
            if parent in issue_map and num not in child_of:
                child_of[num] = parent
                children[parent].append(num)

    # Pass 1: task/epic bodies declare their own parent via "Parent epic: #N".
    for issue in issues:
        num = issue["number"]
        body = issue.get("body", "") or ""
        match = re.search(r"^Parent epic[^:]*: #(\d+)", body, re.MULTILINE)
        if match:
            parent = int(match.group(1))
            if parent in issue_map and num not in child_of:
                child_of[num] = parent
                children[parent].append(num)

    # Pass 2: epics list children in their body/comments (Ordered Checklist).
    for issue in issues:
        num = issue["number"]
        if not is_epic(issue):
            continue
        all_text = (
            (issue.get("body", "") or "")
            + "\n"
            + "\n".join(c["body"] for c in issue["comments"]["nodes"])
        )
        for ref_str in re.findall(r"#(\d+)", all_text):
            ref = int(ref_str)
            if ref == num or ref not in issue_map:
                continue
            if is_epic(issue_map[ref]):
                continue
            if ref not in child_of:
                child_of[ref] = num
                children[num].append(ref)

    return children, child_of


def main():
    issues = get_issues()
    if not issues:
        return

    issue_map = {issue["number"]: issue for issue in issues}
    children, child_of = build_hierarchy(issues, issue_map)

    def child_sort_key(n):
        issue = issue_map[n]
        epic_first = 0 if is_epic(issue) else 1
        tag = task_order_tag(issue)
        if tag is not None:
            return (epic_first, 0, tag, 0)
        return (epic_first, 1, get_priority(issue), n)

    def root_sort_key(n):
        issue = issue_map[n]
        epic_first = 0 if is_epic(issue) else 1
        axis = epic_axis_tag(issue)
        if axis is not None:
            return (epic_first, 0, axis, 0)
        return (epic_first, 1, get_priority(issue), n)

    for parent in children:
        children[parent].sort(key=child_sort_key)

    roots = sorted((num for num in issue_map if num not in child_of), key=root_sort_key)

    def print_tree(num, depth=0):
        issue = issue_map[num]
        priority = get_priority(issue)
        p_str = f"P{priority}" if priority < 99 else "---"
        prefix = "  " * depth
        marker = "↳ " if depth > 0 else ""
        print(f"{prefix}{marker}[{p_str}] #{num} - {issue['title']}")
        for child in children.get(num, []):
            print_tree(child, depth + 1)

    for root in roots:
        print_tree(root)
        if children.get(root):
            print()


if __name__ == "__main__":
    main()
