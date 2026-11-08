#!/usr/bin/env python3
"""Exercise release-history checks against real, disposable Git refs."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class PublicRefTests(unittest.TestCase):
    def test_clone_ahead_notes_and_unreviewed_remote_ref(self):
        with tempfile.TemporaryDirectory(prefix="screenrecall-public-refs-") as directory:
            root = Path(directory)
            work = root / "clone"
            env = dict(os.environ, DENO_DIR=str(root / "deno-cache"),
                       GIT_AUTHOR_NAME="codingEzio",
                       GIT_AUTHOR_EMAIL="22790019+codingEzio@users.noreply.github.com",
                       GIT_COMMITTER_NAME="codingEzio",
                       GIT_COMMITTER_EMAIL="22790019+codingEzio@users.noreply.github.com")
            subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", str(ROOT), str(work)],
                           check=True, capture_output=True, env=env, timeout=30)
            changed = (
                "AGENTS.md", "script/check_public.ts", "script/test_public_refs.py",
                "public-source.json",
            )
            for name in changed:
                shutil.copy2(ROOT / name, work / name)

            def git(*args, input=None):
                return subprocess.run(["git", *args], cwd=work, env=env, input=input,
                                      text=True, capture_output=True, check=True, timeout=30).stdout.strip()

            def check():
                return subprocess.run(["deno", "run", "--allow-run=git", "script/check_public.ts"],
                                      cwd=work, env=env, text=True, capture_output=True, timeout=45)

            git("add", "--", *changed)
            result = check()
            self.assertEqual(result.returncode, 0, result.stderr)

            with (work / "README.md").open("a") as stream:
                stream.write("\n<!-- synthetic ref test -->\n")
            git("add", "--", "README.md")
            git("commit", "--quiet", "-m", "Test an ahead branch")
            result = check()
            self.assertEqual(result.returncode, 0, result.stderr)

            git("notes", "add", "-m", "synthetic note", "HEAD")
            self.assertNotEqual(check().returncode, 0, "notes must be refused")
            git("update-ref", "-d", "refs/notes/commits")

            head = git("rev-parse", "HEAD")
            for ref in ("refs/notes/alias", "refs/replace/" + head, "refs/stash", "refs/custom/alias"):
                git("update-ref", ref, head)
                self.assertNotEqual(check().returncode, 0, f"{ref} must be refused")
                git("update-ref", "-d", ref)

            tree = git("rev-parse", "HEAD^{tree}")
            other = git("commit-tree", tree, input="Synthetic unrelated commit\n")
            blob = git("hash-object", "-w", "--stdin", input="synthetic blob\n")
            git("tag", "-a", "synthetic", "-m", "synthetic", "HEAD")
            tag = git("rev-parse", "refs/tags/synthetic")
            for oid in (other, blob, tree, tag):
                git("update-ref", "refs/remotes/origin/unreviewed", oid)
                result = check()
                self.assertNotEqual(result.returncode, 0, "unreviewed remote ref must be refused")
                self.assertIn("outside the reviewed branch/tag history", result.stderr)
                git("update-ref", "-d", "refs/remotes/origin/unreviewed")
            git("tag", "-d", "synthetic")

            marker = "-----BE" + "GIN RSA PRIVATE " + "KEY-----"
            flagged = git("commit-tree", tree, "-p", head, input=marker + "\n")
            git("update-ref", "refs/tags/synthetic-message", flagged)
            result = check()
            self.assertNotEqual(result.returncode, 0, "sensitive commit messages must be refused")
            self.assertIn("Commit message contains", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-message")

            tag_data = (f"object {head}\ntype commit\ntag synthetic\n"
                        "tagger Other <nobody@example.test> 0 +0000\n\nSynthetic tag\n")
            bad_tag = git("mktag", input=tag_data)
            git("update-ref", "refs/tags/synthetic-tagger", bad_tag)
            result = check()
            self.assertNotEqual(result.returncode, 0, "unreviewed taggers must be refused")
            self.assertIn("Annotated tag contains", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-tagger")

            hidden = work / "Local/history.txt"
            hidden.parent.mkdir(exist_ok=True)
            shutil.copyfile(work / "README.md", hidden)
            git("add", "-f", "--", "Local/history.txt")
            git("commit", "--quiet", "-m", "Create synthetic historical path")
            git("rm", "--quiet", "--", "Local/history.txt")
            git("commit", "--quiet", "-m", "Remove synthetic historical path")
            result = check()
            self.assertNotEqual(result.returncode, 0, "private historical paths must be refused")
            self.assertIn("Local/history.txt: runtime/private path", result.stderr)


if __name__ == "__main__":
    unittest.main()
