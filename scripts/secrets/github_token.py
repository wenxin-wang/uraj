#!/usr/bin/env python3
"""Request a GitHub token tier for contained agents and encrypt it.

GitHub has no API to create personal access tokens, so this opens the token
form with what it can fill in, reads the token you paste back without echoing
it, checks it, and stores it in secrets/shared/github.yaml with SOPS.  Run on
the host, in the project's Guix environment; see secrets/README.org.
"""

import argparse
import getpass
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SECRETS = ROOT / "secrets/shared/github.yaml"
FINE_GRAINED = "https://github.com/settings/personal-access-tokens/new"
CLASSIC = "https://github.com/settings/tokens/new"
# Push, including workflow files, and open pull requests.
PERMISSIONS = {
    "contents": "write",
    "pull_requests": "write",
    "workflows": "write",
}
SCOPES = ("repo", "workflow")
TIERS = {
    "public": "your public repositories",
    "personal": "all your repositories",
    "world": "every repository you can reach",
}


def form_url(tier, owner, days):
    """Return the token form for TIER, filled in as far as GitHub allows."""
    description = f"contained-agent {tier}: {TIERS[tier]}"
    if tier == "world":
        query = {"description": description, "scopes": ",".join(SCOPES)}
        return CLASSIC + "?" + urllib.parse.urlencode(query)
    query = {
        "name": f"contained-agent-{tier}",
        "description": description,
        "target_name": owner,
        "expires_in": days,
        **PERMISSIONS,
    }
    return FINE_GRAINED + "?" + urllib.parse.urlencode(query)


def instructions(tier):
    if tier == "world":
        return (
            "Pick an expiration, keep the scopes filled in "
            f"({', '.join(SCOPES)}), and generate the token."
        )
    if tier == "personal":
        access = "choose `All repositories'"
    else:
        access = "choose `Only select repositories' and pick each listed below"
    granted = ", ".join(f"{k}: {v}" for k, v in PERMISSIONS.items())
    return (
        f"Under Repository access {access}; keep the permissions filled in "
        f"({granted}), and generate the token."
    )


def public_repositories(owner):
    """List OWNER's public repositories with the host's gh login, if any."""
    if not shutil.which("gh"):
        return None
    result = subprocess.run(
        [
            "gh",
            "repo",
            "list",
            owner,
            "--visibility",
            "public",
            "--limit",
            "1000",
            "--json",
            "nameWithOwner",
            "--jq",
            ".[].nameWithOwner",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.stdout.split() if result.returncode == 0 else None


def check(tier, token):
    """Return the token's login and expiration, failing on a wrong kind."""
    classic = tier == "world"
    if token.startswith("github_pat_") == classic:
        sys.exit(
            f"{tier} needs a {'classic' if classic else 'fine-grained'} "
            "token; nothing stored"
        )
    request = urllib.request.Request(
        "https://api.github.com/user",
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        login = json.load(response)["login"]
        if classic:
            scopes = {
                s.strip()
                for s in response.headers.get("x-oauth-scopes", "").split(",")
            }
            if missing := set(SCOPES) - scopes:
                sys.exit(
                    f"token lacks scopes {', '.join(sorted(missing))}; "
                    "nothing stored"
                )
        expiration = response.headers.get(
            "github-authentication-token-expiration", "never"
        )
    return login, expiration


def store(tier, token):
    """Set github.TIER, never passing the token on a command line."""
    if SECRETS.exists():
        command = [
            "sops",
            "set",
            "--value-stdin",
            str(SECRETS),
            f'["github"]["{tier}"]',
        ]
        document = json.dumps(token)
    else:
        SECRETS.parent.mkdir(parents=True, exist_ok=True)
        command = [
            "sops",
            "encrypt",
            "--filename-override",
            str(SECRETS),
            "--input-type",
            "json",
            "--output-type",
            "yaml",
            "--output",
            str(SECRETS),
            "/dev/stdin",
        ]
        document = json.dumps({"github": {tier: token}})
    subprocess.run(command, input=document, text=True, check=True, cwd=ROOT)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "tier",
        choices=TIERS,
        help="; ".join(f"{k}: {v}" for k, v in TIERS.items()),
    )
    parser.add_argument("owner", help="your GitHub user name")
    parser.add_argument(
        "--days",
        default="366",
        help="fine-grained lifetime, 1 to 366 or `none' (default: %(default)s)",
    )
    parser.add_argument(
        "--no-browser", action="store_true", help="only print the form's URL"
    )
    args = parser.parse_args()
    if not shutil.which("sops"):
        sys.exit("sops is not on PATH; enter the project's Guix environment")

    url = form_url(args.tier, args.owner, args.days)
    print(f"{instructions(args.tier)}\n\n  {url}\n")
    if args.tier == "public":
        repositories = public_repositories(args.owner)
        if repositories is None:
            print("(Log in gh on the host to list your public repositories.)")
        else:
            print("\n".join(f"  - {name}" for name in repositories) + "\n")
    opener = shutil.which("xdg-open")
    if opener and not args.no_browser:
        subprocess.run([opener, url], check=False, capture_output=True)

    token = getpass.getpass("Token (not echoed): ").strip()
    try:
        login, expiration = check(args.tier, token)
    except urllib.error.HTTPError as error:
        sys.exit(f"GitHub refused the token: {error.code} {error.reason}")
    except urllib.error.URLError as error:
        sys.exit(f"cannot reach GitHub: {error.reason}; nothing stored")
    if login != args.owner:
        sys.exit(f"the token belongs to {login}, not {args.owner}")
    store(args.tier, token)
    path = SECRETS.relative_to(ROOT)
    print(
        f"Stored github.{args.tier} in {path}; expires {expiration}.\n"
        f"Commit {path}, then reconfigure each host."
    )


if __name__ == "__main__":
    main()
