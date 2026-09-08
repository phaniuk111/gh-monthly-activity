# gh-monthly-activity

Count a GitHub user's **commits** and **pull requests** for a single month — across
public *and* private repositories.

Useful for filling in a monthly status report, a performance-review brag doc, or
answering "what did I actually ship in August?"

```
GitHub activity for @alice in acme-inc — August 2026
Window: 2026-08-01 .. 2026-08-31

Commits authored      : 51
Pull requests opened  : 10
  ...merged in window : 6
  ...closed unmerged  : 4
PRs reviewed by user  : 3
```

---

## Does it work on private repos?

**Yes — provided you give it a token with the right scopes.** Private repos are
not a special mode; they simply become visible once the API calls are
authenticated as someone who can see them.

The difference is stark. Same user, same month:

| | Commits | PRs opened |
|---|---|---|
| **No token** (public repos only) | 30 | 0 |
| **With a `repo`-scoped token** | 51 | 10 |

Both search mode and deep mode return private repositories. GitHub's search
index does cover private repos, but only shows them to a token authorized to
read them.

### What you need

| Token type | Requirement |
|---|---|
| **Classic PAT** | `repo` scope (full, not `public_repo`) + `read:org` if you use `--org` |
| **Fine-grained PAT** | `Contents: read`, `Pull requests: read`, `Metadata: read` — on every repo you want counted |
| **`gh` CLI token** | `gh auth token` works if your login has `repo` + `read:org` (check with `gh auth status`) |

### The three ways private repos silently vanish

These fail *quietly* — you get a number that looks plausible but is too low:

1. **SAML SSO not authorized.** If the org enforces SAML, a valid token is still
   invisible to that org until you click **Configure SSO → Authorize** on the
   token settings page. Private org repos just don't appear. No error.
2. **`public_repo` instead of `repo`.** A common scope slip. Public results only.
3. **Fine-grained PAT with the wrong repo selection.** Fine-grained tokens are
   per-repository; a repo not in the selected list is invisible even with the
   right permissions.

If your numbers look low, verify what the token can actually see:

```bash
gh api "user/repos?visibility=private&per_page=100" --jq '.[].full_name'
```

---

## Install

Requires Python 3.10+ (the code uses `str | None` type syntax).

```bash
git clone <this-repo-url>
cd gh-monthly-activity
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

## Authenticate

```bash
export GITHUB_TOKEN=$(gh auth token)
```

Or use a PAT directly:

```bash
export GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

Or pass it per-run with `--token`. Without any token you get public repos only,
plus a much lower rate limit.

---

## Usage

### Search mode (default — fast)

A handful of API calls. Uses GitHub's global search index.

```bash
python gh_monthly_activity.py alice --month 8 --year 2026
```

Scoped to one organization:

```bash
python gh_monthly_activity.py alice --org acme-inc --month 8
```

With a per-repo and per-PR breakdown:

```bash
python gh_monthly_activity.py alice --org acme-inc --month 8 --details
```

Search mode is the right default. Its two blind spots: it only sees **default
branches**, and it only counts commits whose author email is **verified on the
GitHub account**. Commits made from a laptop with an unregistered
`git config user.email` are invisible to it.

### Deep mode (slower — accurate)

Walks the org's repositories directly instead of trusting the search index.

```bash
python gh_monthly_activity.py alice --org acme-inc --month 8 --deep
```

Every branch, not just the default one:

```bash
python gh_monthly_activity.py alice --org acme-inc --month 8 --deep --all-branches
```

Catch commits GitHub never linked to the account, by raw email:

```bash
python gh_monthly_activity.py alice --org acme-inc --month 8 --deep \
    --all-branches --emails alice@acme.com,alice@localhost
```

Limit to specific repos (works without `--org`, and is by far the fastest way
to sanity-check deep mode):

```bash
python gh_monthly_activity.py alice --month 8 --deep \
    --repos acme/api,acme/web --details
```

---

## Options

| Flag | Meaning |
|---|---|
| `handle` | GitHub username (positional, required) |
| `--org ORG` | Restrict to one organization |
| `--year YYYY` | Defaults to the current year |
| `--month 1-12` | Defaults to `8` |
| `--token` | PAT; defaults to `$GITHUB_TOKEN` |
| `--deep` | Walk repos directly instead of using search. Needs `--org` or `--repos` |
| `--all-branches` | Deep mode: scan every branch, not just the default |
| `--emails a@b,c@d` | Deep mode: also count commits with these raw author emails |
| `--repos a/b,c/d` | Deep mode: limit to these repositories |
| `--include-archived` | Include archived repos (skipped by default) |
| `--details` | Per-repo commit counts and a per-PR listing |

---

## Which mode should I use?

| | Search | Deep |
|---|---|---|
| Speed | seconds | minutes-to-hours on a large org |
| API calls | ~5 (~10 with `--details`) | 2+ per repo, far more with `--all-branches` |
| Non-default branches | no | with `--all-branches` |
| Unlinked commit emails | no | with `--emails` |
| Private repos | yes | yes |
| Result cap | 1000 per query | none |
| `PRs reviewed by user` | yes | not reported |

Start with search mode. Reach for deep mode when the number looks too low and
you suspect feature-branch work or an unregistered commit email.

---

## Known limitations

- **Deep mode undercounts merged PRs.** It stops scanning once it reaches PRs
  created before the window, so a PR opened in July and merged in August is not
  counted in August's merged total. Search mode does not have this problem.
- **Search mode caps at 1000 results** per query, so `--details` truncates for
  very high-volume months. The summary counts are unaffected.
- **`--all-branches` is expensive.** It lists every branch and walks each one;
  on a repo with hundreds of branches this burns a lot of rate limit. Combine
  with `--repos` to keep it bounded.
- **Deep mode ignores forks' upstream activity** — it counts what is in the
  repos it enumerates, nothing else.
- Rate limits are handled by sleeping until reset, so a large `--deep` run can
  pause for a long stretch rather than failing.
