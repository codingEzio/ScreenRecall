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
            result = check()
            self.assertEqual(result.returncode, 0, result.stderr)
            for oid in (other, blob, tree, tag):
                git("update-ref", "refs/remotes/origin/unreviewed", oid)
                result = check()
                self.assertNotEqual(result.returncode, 0, "unreviewed remote ref must be refused")
                self.assertIn("outside the reviewed branch/tag history", result.stderr)
                git("update-ref", "-d", "refs/remotes/origin/unreviewed")
            git("tag", "-d", "synthetic")

            valid_outer_data = (f"object {tag}\ntype tag\ntag outer\n"
                                "tagger codingEzio <22790019+codingEzio@users.noreply.github.com> 0 +0000\n\nOuter\n")
            valid_outer = git("mktag", input=valid_outer_data)
            git("update-ref", "refs/tags/synthetic-valid-outer", valid_outer)
            result = check()
            self.assertEqual(result.returncode, 0, result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-valid-outer")

            secret_ref = "refs/tags/" + "gh" + "p_" + "A" * 30
            git("update-ref", secret_ref, head)
            result = check()
            self.assertNotEqual(result.returncode, 0, "sensitive ref names must be refused")
            self.assertIn("Git ref contains", result.stderr)
            git("update-ref", "-d", secret_ref)

            marker = "-----BE" + "GIN RSA PRIVATE " + "KEY-----"
            flagged = git("commit-tree", tree, "-p", head, input=marker + "\n")
            git("update-ref", "refs/tags/synthetic-message", flagged)
            result = check()
            self.assertNotEqual(result.returncode, 0, "sensitive commit messages must be refused")
            self.assertIn("Commit metadata or message contains", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-message")

            identity = "codingEzio <22790019+codingEzio@users.noreply.github.com>"
            private_path = "/" + "Users/" + "synthetic/" + "private"
            raw = (f"tree {tree}\nparent {head}\nauthor {identity} 0 +0000\n"
                   f"committer {identity} 0 +0000\nx-extra {private_path}\n\nSynthetic\n")
            header_commit = git("hash-object", "--literally", "-t", "commit", "-w", "--stdin", input=raw)
            git("update-ref", "refs/tags/synthetic-header", header_commit)
            result = check()
            self.assertNotEqual(result.returncode, 0, "sensitive commit headers must be refused")
            self.assertIn("Commit metadata or message contains", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-header")

            tag_data = (f"object {head}\ntype commit\ntag synthetic\n"
                        "tagger Other <nobody@example.test> 0 +0000\n\nSynthetic tag\n")
            bad_tag = git("mktag", input=tag_data)
            git("update-ref", "refs/tags/synthetic-tagger", bad_tag)
            result = check()
            self.assertNotEqual(result.returncode, 0, "unreviewed taggers must be refused")
            self.assertIn("Annotated tag contains", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-tagger")

            spoof_data = (f"object {head}\ntype commit\ntag spoof\n\n"
                          "tagger codingEzio <22790019+codingEzio@users.noreply.github.com> 0 +0000\n")
            spoof = git("hash-object", "--literally", "-t", "tag", "-w", "--stdin", input=spoof_data)
            git("update-ref", "refs/tags/synthetic-spoof", spoof)
            result = check()
            self.assertNotEqual(result.returncode, 0, "a tagger in the message is not a header")
            self.assertIn("Annotated tag contains", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-spoof")

            sensitive_tag = (f"object {head}\ntype commit\ntag inner\n"
                             "tagger codingEzio <22790019+codingEzio@users.noreply.github.com> 0 +0000\n\n"
                             + marker + "\n")
            secret_inner = git("mktag", input=sensitive_tag)
            for inner in (bad_tag, secret_inner):
                outer_data = (f"object {inner}\ntype tag\ntag outer\n"
                              "tagger codingEzio <22790019+codingEzio@users.noreply.github.com> 0 +0000\n\nOuter\n")
                outer = git("mktag", input=outer_data)
                git("update-ref", "refs/tags/synthetic-outer", outer)
                result = check()
                self.assertNotEqual(result.returncode, 0, "nested tags must be inspected")
                self.assertIn("Annotated tag contains", result.stderr)
                git("update-ref", "-d", "refs/tags/synthetic-outer")

            git("update-ref", "refs/tags/synthetic-blob", blob)
            result = check()
            self.assertNotEqual(result.returncode, 0, "release tags must resolve to commits")
            self.assertIn("Release refs must resolve to commits", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-blob")

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
