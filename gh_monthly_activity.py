#!/usr/bin/env python3
"""
Count commits and pull requests for a GitHub handle in a given month.

Two modes:

  SEARCH mode (default, fast)
      Uses GitHub's global search index. A few API calls total.
      Only sees DEFAULT branches, and only commits whose author email is
      verified on the account.

        python gh_monthly_activity.py alice --org acme-inc --month 8

  DEEP mode (--deep, accurate)
      Enumerates the org's repos and walks them directly. Slower, but sees
      every branch (with --all-branches) and can match raw commit emails
      that GitHub never linked to the account (with --emails).

        python gh_monthly_activity.py alice --org acme-inc --month 8 --deep \\
            --all-branches --emails alice@acme.com,alice@localhost

Token:
    export GITHUB_TOKEN=ghp_xxx        # or pass --token
    Classic PAT needs `repo` + `read:org`.  If your org enforces SAML SSO you
    must click "Configure SSO" on the token and authorize it for the org,
    otherwise private repos silently disappear from the results.
    Fine-grained PAT needs Contents:read, Pull requests:read, Metadata:read
    on the repos in question.
"""

import argparse
import calendar
import os
import sys
import time
from collections import Counter
from datetime import date, datetime, timezone
from urllib.parse import urlencode

import requests

API = "https://api.github.com"


# ----------------------------------------------------------------------------
# HTTP plumbing
# ----------------------------------------------------------------------------

class GH:
    def __init__(self, token: str | None):
        self.s = requests.Session()
        self.s.headers.update({
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        if token:
            self.s.headers["Authorization"] = f"Bearer {token}"
        self.calls = 0

    def get(self, url: str, **params):
        if params:
            url = f"{url}?{urlencode(params)}"
        while True:
            r = self.s.get(url, timeout=30)
            self.calls += 1

            if r.status_code in (403, 429):
                remaining = r.headers.get("X-RateLimit-Remaining")
                if remaining == "0":
                    reset = int(r.headers.get("X-RateLimit-Reset", time.time() + 60))
                    wait = max(5, reset - int(time.time()) + 2)
                    print(f"    rate limited — sleeping {wait}s", file=sys.stderr)
                    time.sleep(wait)
                    continue
                retry = r.headers.get("Retry-After")
                if retry:
                    time.sleep(int(retry) + 1)
                    continue

            if r.status_code == 409:      # empty repository
                return None, r
            if r.status_code == 404:
                return None, r
            if r.status_code != 200:
                raise SystemExit(f"GitHub API error {r.status_code} on {url}\n{r.text[:400]}")
            return r.json(), r

    def paginate(self, url: str, cap: int | None = None, **params):
        """Yield items across pages, following the Link header."""
        params.setdefault("per_page", 100)
        first = f"{url}?{urlencode(params)}"
        n = 0
        while first:
            data, r = self.get(first)
            if data is None:
                return
            items = data["items"] if isinstance(data, dict) and "items" in data else data
            for it in items:
                yield it
                n += 1
                if cap and n >= cap:
                    return
            nxt = r.links.get("next")
            first = nxt["url"] if nxt else None


# ----------------------------------------------------------------------------
# helpers
# ----------------------------------------------------------------------------

def month_range(year: int, month: int):
    last = calendar.monthrange(year, month)[1]
    return date(year, month, 1), date(year, month, last)


def iso_z(d: date, end: bool = False) -> str:
    t = "T23:59:59Z" if end else "T00:00:00Z"
    return d.isoformat() + t


def parse_ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)


# ----------------------------------------------------------------------------
# SEARCH mode
# ----------------------------------------------------------------------------

def count(gh: GH, endpoint: str, q: str) -> int:
    data, _ = gh.get(f"{API}/search/{endpoint}", q=q, per_page=1)
    time.sleep(0.7)   # search API is 30 req/min authenticated
    return data.get("total_count", 0) if data else 0


def run_search(gh: GH, user: str, org: str | None, start: date, end: date, details: bool):
    s, e = start.isoformat(), end.isoformat()
    scope = f" org:{org}" if org else ""

    commits = count(gh, "commits", f"author:{user} author-date:{s}..{e}{scope}")
    opened = count(gh, "issues", f"type:pr author:{user} created:{s}..{e}{scope}")
    merged = count(gh, "issues", f"type:pr author:{user} merged:{s}..{e}{scope}")
    unmerged = count(gh, "issues", f"type:pr author:{user} closed:{s}..{e} is:unmerged{scope}")
    reviewed = count(gh, "issues", f"type:pr reviewed-by:{user} updated:{s}..{e}{scope}")

    report(commits, opened, merged, unmerged, reviewed)

    if details:
        print("\nCommits by repo:")
        items = gh.paginate(f"{API}/search/commits", cap=1000,
                            q=f"author:{user} author-date:{s}..{e}{scope}")
        c = Counter(i["repository"]["full_name"] for i in items)
        for repo, n in c.most_common():
            print(f"  {n:>4}  {repo}")

        print("\nPull requests opened:")
        prs = gh.paginate(f"{API}/search/issues", cap=1000,
                          q=f"type:pr author:{user} created:{s}..{e}{scope}")
        for i in sorted(prs, key=lambda x: x["created_at"]):
            repo = i["repository_url"].split("/repos/")[-1]
            state = "merged" if i.get("pull_request", {}).get("merged_at") else i["state"]
            print(f"  {i['created_at'][:10]}  [{state:>6}]  {repo}#{i['number']}  {i['title'][:70]}")


# ----------------------------------------------------------------------------
# DEEP mode
# ----------------------------------------------------------------------------

def org_repos(gh: GH, org: str, include_archived: bool, only: list[str] | None):
    if only:
        for full in only:
            owner, _, name = full.partition("/")
            if not name:
                owner, name = org, owner
            data, _ = gh.get(f"{API}/repos/{owner}/{name}")
            if data:
                yield data
        return
    for r in gh.paginate(f"{API}/orgs/{org}/repos", type="all", sort="pushed"):
        if r.get("archived") and not include_archived:
            continue
        yield r


def repo_commits(gh: GH, repo: dict, user: str, emails: set[str],
                 start: date, end: date, all_branches: bool):
    """Return {sha: commit} authored by the user in the window."""
    owner_repo = repo["full_name"]
    since, until = iso_z(start), iso_z(end, end=True)
    found: dict[str, dict] = {}

    if all_branches:
        refs = [b["name"] for b in gh.paginate(f"{API}/repos/{owner_repo}/branches")]
    else:
        refs = [repo.get("default_branch") or "HEAD"]

    for ref in refs:
        params = {"sha": ref, "since": since, "until": until}
        # If we're only trusting GitHub's account linkage, let the API filter.
        # If the user supplied raw emails, pull everything and filter locally.
        if not emails:
            params["author"] = user
        for c in gh.paginate(f"{API}/repos/{owner_repo}/commits", **params):
            if c["sha"] in found:
                continue
            if emails:
                login = (c.get("author") or {}).get("login", "")
                mail = ((c.get("commit") or {}).get("author") or {}).get("email", "")
                if login.lower() != user.lower() and mail.lower() not in emails:
                    continue
            found[c["sha"]] = c

    return found


def repo_prs(gh: GH, repo: dict, user: str, start: date, end: date):
    """Return PRs in this repo, split into opened / merged / closed-unmerged."""
    opened, merged, unmerged = [], [], []
    start_dt = parse_ts(iso_z(start))
    end_dt = parse_ts(iso_z(end, end=True))

    for pr in gh.paginate(f"{API}/repos/{repo['full_name']}/pulls",
                          state="all", sort="created", direction="desc"):
        created = parse_ts(pr["created_at"])
        if created < start_dt:
            break              # sorted desc — everything after is older
        if (pr["user"] or {}).get("login", "").lower() != user.lower():
            continue
        if created <= end_dt:
            opened.append(pr)
        if pr.get("merged_at") and start_dt <= parse_ts(pr["merged_at"]) <= end_dt:
            merged.append(pr)
        elif pr.get("closed_at") and not pr.get("merged_at") \
                and start_dt <= parse_ts(pr["closed_at"]) <= end_dt:
            unmerged.append(pr)
    return opened, merged, unmerged


def run_deep(gh: GH, user: str, org: str, start: date, end: date,
             emails: set[str], all_branches: bool, include_archived: bool,
             only: list[str] | None, details: bool):

    per_repo_commits: Counter = Counter()
    all_opened, all_merged, all_unmerged = [], [], []
    total_commits = 0

    repos = list(org_repos(gh, org, include_archived, only))
    print(f"Scanning {len(repos)} repositories in {org}"
          f"{' (all branches)' if all_branches else ''}...\n", file=sys.stderr)

    for idx, repo in enumerate(repos, 1):
        name = repo["full_name"]
        print(f"  [{idx}/{len(repos)}] {name}", file=sys.stderr)

        commits = repo_commits(gh, repo, user, emails, start, end, all_branches)
        if commits:
            per_repo_commits[name] = len(commits)
            total_commits += len(commits)

        o, m, u = repo_prs(gh, repo, user, start, end)
        all_opened += [(name, p) for p in o]
        all_merged += [(name, p) for p in m]
        all_unmerged += [(name, p) for p in u]

    print(file=sys.stderr)
    report(total_commits, len(all_opened), len(all_merged), len(all_unmerged), None)

    if details:
        if per_repo_commits:
            print("\nCommits by repo:")
            for repo, n in per_repo_commits.most_common():
                print(f"  {n:>4}  {repo}")
        if all_opened:
            print("\nPull requests opened:")
            for name, pr in sorted(all_opened, key=lambda x: x[1]["created_at"]):
                state = "merged" if pr.get("merged_at") else pr["state"]
                print(f"  {pr['created_at'][:10]}  [{state:>6}]  "
                      f"{name}#{pr['number']}  {pr['title'][:70]}")

    print(f"\n({gh.calls} API calls)", file=sys.stderr)


# ----------------------------------------------------------------------------

def report(commits, opened, merged, unmerged, reviewed):
    print(f"Commits authored      : {commits}")
    print(f"Pull requests opened  : {opened}")
    print(f"  ...merged in window : {merged}")
    print(f"  ...closed unmerged  : {unmerged}")
    if reviewed is not None:
        print(f"PRs reviewed by user  : {reviewed}")


def main():
    p = argparse.ArgumentParser(
        description="Count a GitHub user's commits and PRs for one month",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("handle", help="GitHub username, e.g. alice")
    p.add_argument("--org", help="restrict to this organization")
    p.add_argument("--year", type=int, default=date.today().year)
    p.add_argument("--month", type=int, default=8, help="1-12 (default 8 = August)")
    p.add_argument("--token", default=os.environ.get("GITHUB_TOKEN"),
                   help="PAT, or set GITHUB_TOKEN")
    p.add_argument("--deep", action="store_true",
                   help="walk org repos directly instead of using search (needs --org)")
    p.add_argument("--all-branches", action="store_true",
                   help="deep mode: scan every branch, not just default")
    p.add_argument("--emails", default="",
                   help="deep mode: comma-separated commit emails to also count "
                        "(catches commits GitHub never linked to the account)")
    p.add_argument("--repos", default="",
                   help="deep mode: comma-separated repos to limit to, e.g. acme/api,acme/web")
    p.add_argument("--include-archived", action="store_true")
    p.add_argument("--details", action="store_true", help="per-repo and per-PR breakdown")
    args = p.parse_args()

    if not args.token:
        print("WARNING: no token — private repos invisible and rate limits are brutal.\n",
              file=sys.stderr)
    if args.deep and not args.org and not args.repos:
        raise SystemExit("--deep needs --org (or --repos)")

    start, end = month_range(args.year, args.month)
    gh = GH(args.token)

    print(f"GitHub activity for @{args.handle}"
          f"{' in ' + args.org if args.org else ''} — "
          f"{calendar.month_name[args.month]} {args.year}")
    print(f"Window: {start} .. {end}\n")

    if args.deep:
        emails = {e.strip().lower() for e in args.emails.split(",") if e.strip()}
        only = [r.strip() for r in args.repos.split(",") if r.strip()] or None
        run_deep(gh, args.handle, args.org, start, end, emails,
                 args.all_branches, args.include_archived, only, args.details)
    else:
        run_search(gh, args.handle, args.org, start, end, args.details)


if __name__ == "__main__":
    main()
