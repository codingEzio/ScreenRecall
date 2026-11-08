#!/usr/bin/env python3
"""Exercise release-history checks against real, disposable Git refs."""

import json
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
            env = dict(os.environ, DENO_DIR=str(root / "deno-cache"),
                       GIT_AUTHOR_NAME="codingEzio",
                       GIT_AUTHOR_EMAIL="22790019+codingEzio@users.noreply.github.com",
                       GIT_COMMITTER_NAME="codingEzio",
                       GIT_COMMITTER_EMAIL="22790019+codingEzio@users.noreply.github.com")
            origin = root / "origin"
            origin.mkdir()
            (origin / "script").mkdir()
            shutil.copy2(ROOT / "script/check_public.ts", origin / "script/check_public.ts")
            (origin / ".gitignore").write_text("Local/\n")
            (origin / "README.md").write_text("# Synthetic project\n")
            files = [".gitignore", "README.md", "public-source.json", "script/check_public.ts"]
            (origin / "public-source.json").write_text(json.dumps({
                "files": files, "assets": {}, "fontFiles": [],
            }) + "\n")
            subprocess.run(["git", "init", "--quiet", "-b", "main"], cwd=origin,
                           check=True, capture_output=True, env=env, timeout=30)
            subprocess.run(["git", "add", "--", *files], cwd=origin,
                           check=True, capture_output=True, env=env, timeout=30)
            subprocess.run(["git", "commit", "--quiet", "-m", "Synthetic base"], cwd=origin,
                           check=True, capture_output=True, env=env, timeout=30)
            with (origin / "README.md").open("a") as stream:
                stream.write("Second synthetic commit.\n")
            subprocess.run(["git", "add", "--", "README.md"], cwd=origin,
                           check=True, capture_output=True, env=env, timeout=30)
            subprocess.run(["git", "commit", "--quiet", "-m", "Synthetic update"], cwd=origin,
                           check=True, capture_output=True, env=env, timeout=30)
            work = root / "clone"
            subprocess.run(["git", "clone", "--quiet", "--no-hardlinks", str(origin), str(work)],
                           check=True, capture_output=True, env=env, timeout=30)

            def git(*args, input=None):
                return subprocess.run(["git", *args], cwd=work, env=env, input=input,
                                      text=True, capture_output=True, check=True, timeout=30).stdout.strip()

            def check(extra_env=None):
                check_env = dict(env)
                check_env.update(extra_env or {})
                return subprocess.run(["deno", "run", "--allow-run=git", "script/check_public.ts"],
                                      cwd=work, env=check_env, text=True, capture_output=True, timeout=45)

            shallow = root / "shallow"
            subprocess.run(["git", "clone", "--quiet", "--depth=1", origin.as_uri(), str(shallow)],
                           check=True, capture_output=True, env=env, timeout=30)
            result = subprocess.run(["deno", "run", "--allow-run=git", "script/check_public.ts"],
                                    cwd=shallow, env=env, text=True, capture_output=True, timeout=45)
            self.assertNotEqual(result.returncode, 0, "shallow history must be refused")
            self.assertIn("Shallow Git history", result.stderr)

            result = check()
            self.assertEqual(result.returncode, 0, result.stderr)

            with (work / "README.md").open("a") as stream:
                stream.write("\n<!-- synthetic ref test -->\n")
            git("add", "--", "README.md")
            git("commit", "--quiet", "-m", "Test an ahead branch")
            result = check()
            self.assertEqual(result.returncode, 0, result.stderr)

            head = git("rev-parse", "HEAD")
            tree = git("rev-parse", "HEAD^{tree}")
            detached = git("commit-tree", tree, "-p", head, input="Synthetic detached commit\n")
            git("switch", "--quiet", "--detach", detached)
            result = check()
            self.assertNotEqual(result.returncode, 0, "unreviewed detached HEAD must be refused")
            self.assertIn("HEAD is outside the reviewed branch/tag history", result.stderr)
            git("switch", "--quiet", "main")

            late = work / "Local/late.txt"
            late.parent.mkdir(exist_ok=True)
            late.write_text("synthetic late file\n")
            wrappers = root / "wrappers"
            wrappers.mkdir()
            wrapper = wrappers / "git"
            wrapper.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
real = os.environ["REAL_GIT"]
if "ls-files" in args and "-z" in args:
    result = subprocess.run([real, *args], capture_output=True)
    subprocess.run([real, "add", "-f", "--", "Local/late.txt"], check=True, capture_output=True)
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    sys.exit(result.returncode)
os.execv(real, [real, *args])
''')
            wrapper.chmod(0o755)
            result = check({"PATH": str(wrappers) + os.pathsep + env["PATH"],
                            "REAL_GIT": shutil.which("git")})
            self.assertNotEqual(result.returncode, 0, "concurrent index writes must be refused")
            self.assertIn("Git index changed during review", result.stderr)
            git("rm", "--cached", "--quiet", "--", "Local/late.txt")
            late.unlink()

            link = work / "script/synthetic-link"
            link.symlink_to("../README.md")
            git("add", "--", "script/synthetic-link")
            result = check()
            self.assertNotEqual(result.returncode, 0, "indexed symlinks must be refused")
            self.assertIn("non-regular indexed file", result.stderr)
            git("rm", "--cached", "--quiet", "--", "script/synthetic-link")
            link.unlink()

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

            duplicate_author = (f"tree {tree}\nparent {head}\n"
                                "author Synthetic <nobody@example.test> 0 +0000\n"
                                f"author {identity} 0 +0000\ncommitter {identity} 0 +0000\n\nSynthetic\n")
            duplicate = git("hash-object", "--literally", "-t", "commit", "-w", "--stdin", input=duplicate_author)
            git("update-ref", "refs/tags/synthetic-duplicate-author", duplicate)
            result = check()
            self.assertNotEqual(result.returncode, 0, "ambiguous commit identity must be refused")
            self.assertIn("Commit contains an unexpected or ambiguous identity", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-duplicate-author")

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

            sensitive_name = "gh" + "p_" + "A" * 30
            empty = git("mktree", input="")
            root_entries = git("ls-tree", "HEAD")
            empty_tree = git("mktree", input=root_entries + f"\n040000 tree {empty}\t{sensitive_name}\n")
            empty_commit = git("commit-tree", empty_tree, "-p", head, input="Synthetic empty tree\n")
            git("update-ref", "refs/tags/synthetic-empty-tree", empty_commit)
            result = check()
            self.assertNotEqual(result.returncode, 0, "sensitive empty directory names must be refused")
            self.assertIn("[redacted path]: private or sensitive historical directory", result.stderr)
            self.assertNotIn(sensitive_name, result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-empty-tree")

            # The same blob and pathname can have a different mode in an older tree.
            # The newer regular file must not hide the historical symlink.
            root_entries = git("ls-tree", head)
            readme_line = next(line for line in root_entries.splitlines() if line.endswith("\tREADME.md"))
            self.assertTrue(readme_line.startswith("100644 blob "))
            old_entries = root_entries.replace(readme_line, "120000" + readme_line[6:])
            old_tree = git("mktree", input=old_entries + "\n")
            old_commit = git("commit-tree", old_tree, "-p", head, input="Synthetic old symlink\n")
            new_commit = git("commit-tree", tree, "-p", old_commit, input="Synthetic regular file\n")
            git("update-ref", "refs/tags/synthetic-reused-mode", new_commit)
            result = check()
            self.assertNotEqual(result.returncode, 0, "reused blob and path must not hide an old symlink")
            self.assertIn("README.md: non-regular historical source", result.stderr)
            git("update-ref", "-d", "refs/tags/synthetic-reused-mode")

            link.symlink_to("../README.md")
            git("add", "--", "script/synthetic-link")
            git("commit", "--quiet", "-m", "Create synthetic historical symlink")
            git("rm", "--quiet", "--", "script/synthetic-link")
            git("commit", "--quiet", "-m", "Remove synthetic historical symlink")
            result = check()
            self.assertNotEqual(result.returncode, 0, "historical symlinks must be refused")
            self.assertIn("non-regular historical source", result.stderr)

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

            token_file = work / (sensitive_name + ".txt")
            token_file.write_text("synthetic ordinary content\n")
            git("add", "--", token_file.name)
            git("commit", "--quiet", "-m", "Create synthetic sensitive pathname")
            git("rm", "--quiet", "--", token_file.name)
            git("commit", "--quiet", "-m", "Remove synthetic sensitive pathname")
            result = check()
            self.assertNotEqual(result.returncode, 0, "sensitive historical filenames must be refused")
            self.assertIn("[redacted path]: sensitive path pattern", result.stderr)
            self.assertNotIn(sensitive_name, result.stderr)


if __name__ == "__main__":
    unittest.main()
