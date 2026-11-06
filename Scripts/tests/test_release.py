"""Release safety checks use a simulated GitHub; no subprocess or network is allowed."""

import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("malysh_release", Path(__file__).parents[1] / "release.py")
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class FakeRemote:
    """Small stateful fake: only declared git/gh commands are accepted."""

    branch = "nnafranets/feature/ready"
    head = "a" * 40
    base = "b" * 40
    merged = "c" * 40
    version = "v1.9.0"

    def __init__(self, root):
        self.root = str(root)
        self.origin = "git@github.com:dimensi/malysh.git"
        self.push_origin = self.origin
        self.dirty = ""
        self.main = self.base
        self.local_branch_head = self.head
        self.move_branch_before_push = False
        self.race_tag_after_creation = False
        self.move_tag_ref_after_resolution = False
        self.tag_object = "f" * 40
        self.tag_objects = {self.tag_object: self.merged}
        self.remote_branch = None
        self.remote_tag = None
        self.local_tag = None
        self.pull = None
        self.published_release = False
        self.lose_tag_response = False
        self.calls = []
        self.tag_pushes = 0

    def result(self, command, stdout="", returncode=0, stderr="", check=True):
        if check and returncode:
            raise release.ReleaseError(stderr or "synthetic command failure")
        return subprocess.CompletedProcess(command, returncode, stdout, stderr)

    def __call__(self, command, *, check=True):
        command = list(command)
        self.calls.append(command)
        stdout = ""
        code = 0
        stderr = ""

        if command == ["git", "rev-parse", "--show-toplevel"]:
            stdout = self.root + "\n"
        elif command == ["git", "symbolic-ref", "--quiet", "--short", "HEAD"]:
            stdout = self.branch + "\n"
        elif command == ["git", "remote", "get-url", "origin"]:
            stdout = self.origin + "\n"
        elif command == ["git", "remote", "get-url", "--push", "--all", "origin"]:
            stdout = self.push_origin + "\n"
        elif command == ["git", "status", "--porcelain=v1", "--untracked-files=all"]:
            stdout = self.dirty
        elif command[:4] == ["gh", "repo", "view", "dimensi/malysh"]:
            stdout = json.dumps({"nameWithOwner": "dimensi/malysh", "viewerPermission": "ADMIN"})
        elif command == ["git", "fetch", "--no-tags", "origin", "main"]:
            pass
        elif command == ["git", "rev-parse", "FETCH_HEAD"]:
            stdout = self.main + "\n"
        elif command == ["git", "rev-parse", "HEAD"]:
            stdout = self.head + "\n"
        elif command == ["git", "ls-remote", "origin", f"refs/heads/{self.branch}"]:
            stdout = f"{self.remote_branch}\trefs/heads/{self.branch}\n" if self.remote_branch else ""
            if self.move_branch_before_push:
                # Another process advances the local branch after HEAD was captured.
                self.local_branch_head = "d" * 40
                self.move_branch_before_push = False
        elif command[:4] == ["git", "ls-remote", "--tags", "origin"]:
            stdout = (f"{'e' * 40}\trefs/tags/{self.version}\n"
                      f"{self.remote_tag}\trefs/tags/{self.version}^{{}}\n") if self.remote_tag else ""
        elif command == ["git", "rev-parse", "--verify", "--quiet", f"refs/tags/{self.version}^{{commit}}"]:
            stdout, code = (self.local_tag + "\n", 0) if self.local_tag else ("", 1)
        elif command == ["git", "rev-parse", "--verify", f"refs/tags/{self.version}"]:
            stdout = self.tag_object + "\n"
            if self.move_tag_ref_after_resolution:
                self.local_tag = "d" * 40
                self.tag_object = "1" * 40
                self.tag_objects[self.tag_object] = self.local_tag
                self.move_tag_ref_after_resolution = False
        elif command[:3] == ["git", "rev-parse", "--verify"] and command[3].endswith("^{commit}"):
            stdout = self.tag_objects[command[3].removesuffix("^{commit}")] + "\n"
        elif command == ["git", "cat-file", "-t", f"refs/tags/{self.version}"]:
            stdout = "tag\n"
        elif command[:3] == ["git", "cat-file", "-t"] and command[3] in self.tag_objects:
            stdout = "tag\n"
        elif command[:4] == ["git", "merge-base", "--is-ancestor", self.base]:
            pass
        elif command[:4] == ["git", "merge-base", "--is-ancestor", self.merged]:
            pass
        elif command == ["git", "log", "-1", "--format=%s"]:
            stdout = "Обновить интерфейс\n"
        elif command[:3] == ["gh", "api", f"repos/dimensi/malysh/releases/tags/{self.version}"]:
            if self.published_release:
                stdout = json.dumps({"tag_name": self.version, "html_url": self.release_url})
            else:
                code, stderr = 1, "HTTP 404"
        elif command[:3] == ["gh", "pr", "list"]:
            stdout = json.dumps([self.pull] if self.pull else [])
        elif command[:3] == ["gh", "pr", "view"]:
            stdout = json.dumps(self.pull)
        elif command[:3] == ["gh", "pr", "create"]:
            self.pull = {"number": 19, "url": "https://github.com/dimensi/malysh/pull/19",
                         "state": "OPEN", "headRefName": self.branch, "headRefOid": self.remote_branch,
                         "baseRefName": "main", "mergeCommit": None}
            stdout = self.pull["url"] + "\n"
        elif command[:3] == ["gh", "pr", "merge"]:
            self.pull = {**self.pull, "state": "MERGED", "mergeCommit": {"oid": self.merged}}
            self.main = self.merged
        elif command[:3] == ["gh", "release", "create"]:
            self.published_release = True
            stdout = self.release_url + "\n"
        elif command[:3] == ["git", "push", "origin"] and command[3].endswith(f":refs/heads/{self.branch}"):
            source = command[3].split(":", 1)[0]
            if source == f"refs/heads/{self.branch}":
                self.remote_branch = self.local_branch_head
            elif source == self.head:
                self.remote_branch = source
            else:
                raise AssertionError(f"Unexpected push source: {source}")
        elif command[:3] == ["git", "tag", "-a"]:
            self.local_tag = command[4]
            if self.race_tag_after_creation:
                self.remote_tag = "d" * 40
        elif command[:3] == ["git", "push", "origin"] and command[3].endswith(f":refs/tags/{self.version}"):
            self.tag_pushes += 1
            source = command[3].split(":", 1)[0]
            self.remote_tag = self.tag_objects[source]
            if self.lose_tag_response:
                self.lose_tag_response = False
                raise release.ReleaseError("соединение прервано после отправки")
        elif command[:2] == ["git", "push"] and any(arg == f":refs/heads/{self.branch}" for arg in command):
            self.remote_branch = None
        else:
            raise AssertionError(f"Unexpected command: {command!r}")
        return self.result(command, stdout, code, stderr, check)

    @property
    def release_url(self):
        return f"https://github.com/dimensi/malysh/releases/tag/{self.version}"

    def writes(self):
        return [c for c in self.calls if c[:2] in (["git", "push"], ["git", "tag"])
                or c[:3] in (["gh", "pr", "create"], ["gh", "pr", "merge"], ["gh", "release", "create"])]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.remote = FakeRemote(Path(temp.name))
        for target, kwargs in [
            ("subprocess.run", {"side_effect": AssertionError("Real subprocess is forbidden")}),
            ("os.chdir", {}),
        ]:
            patcher = patch(target, **kwargs)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(release, "run", side_effect=self.remote)
        patcher.start()
        self.addCleanup(patcher.stop)

    def publish(self):
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return release.publish(release.parse_args([self.remote.version]))

    def test_dirty_or_unexpected_origin_stops_before_publication(self):
        for field, value in [("dirty", " M Sources/App.swift\n"),
                             ("origin", "git@github.com:another/project.git"),
                             ("push_origin", "git@github.com:another/project.git")]:
            with self.subTest(field=field):
                setattr(self.remote, field, value)
                with self.assertRaises(release.ReleaseError):
                    self.publish()
                self.assertEqual(self.remote.writes(), [])
                setattr(self.remote, field, "" if field == "dirty" else "git@github.com:dimensi/malysh.git")

    def test_publish_pushes_merges_and_tags_the_actual_merge_commit(self):
        self.publish()
        writes = self.remote.writes()
        self.assertEqual([c[:3] for c in writes], [
            ["git", "push", "origin"], ["gh", "pr", "create"], ["gh", "pr", "merge"],
            ["git", "tag", "-a"], ["git", "push", "origin"], ["gh", "release", "create"],
            ["git", "push", f"--force-with-lease=refs/heads/{self.remote.branch}:{self.remote.head}"],
        ])
        self.assertIn("--squash", writes[2])
        self.assertIn("--fill", writes[1])
        self.assertNotIn("--body", writes[1])
        self.assertEqual(writes[0][3], f"{self.remote.head}:refs/heads/{self.remote.branch}")
        self.assertEqual(writes[2][writes[2].index("--match-head-commit") + 1], self.remote.head)
        self.assertEqual(writes[3][4], self.remote.merged)
        self.assertEqual(writes[4][3], f"{self.remote.tag_object}:refs/tags/{self.remote.version}")
        self.assertEqual(self.remote.remote_tag, self.remote.merged)
        self.assertTrue(self.remote.published_release)
        self.assertIsNone(self.remote.remote_branch)
        self.assertFalse(any("workflow" in c or "run" in c for c in self.remote.calls))

    def test_uncertain_tag_push_reports_error_and_retry_never_pushes_tag_twice(self):
        self.remote.lose_tag_response = True
        error = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(error):
            exit_code = release.main([self.remote.version])
        self.assertEqual(exit_code, 1)
        self.assertIn("Не удалось подтвердить шаг «отправка тега»", error.getvalue())
        self.assertIn("соединение прервано после отправки", error.getvalue())
        self.assertEqual(self.remote.remote_tag, self.remote.merged)
        self.assertFalse(self.remote.published_release)
        self.publish()
        self.assertEqual(self.remote.tag_pushes, 1)
        self.assertTrue(self.remote.published_release)

    def test_tag_owned_by_another_commit_stops_before_branch_push(self):
        self.remote.remote_tag = "d" * 40
        with self.assertRaisesRegex(release.ReleaseError, "уже занят"):
            self.publish()
        self.assertEqual(self.remote.writes(), [])

    def test_concurrent_local_branch_advance_cannot_change_the_pushed_commit(self):
        self.remote.move_branch_before_push = True
        self.publish()
        push = self.remote.writes()[0]
        self.assertEqual(self.remote.local_branch_head, "d" * 40)
        self.assertEqual(push[3], f"{self.remote.head}:refs/heads/{self.remote.branch}")
        self.assertEqual(self.remote.pull["headRefOid"], self.remote.head)

    def test_tag_created_by_another_publisher_after_local_tag_stops_push(self):
        self.remote.race_tag_after_creation = True
        with self.assertRaisesRegex(release.ReleaseError, "тег изменился перед отправкой"):
            self.publish()
        self.assertEqual(self.remote.tag_pushes, 0)
        self.assertFalse(self.remote.published_release)

    def test_tag_ref_change_after_resolution_cannot_send_different_tag_object(self):
        original_object = self.remote.tag_object
        self.remote.move_tag_ref_after_resolution = True
        self.publish()
        self.assertEqual(self.remote.local_tag, "d" * 40)
        pushes = [c for c in self.remote.writes()
                  if c[:3] == ["git", "push", "origin"] and c[3].endswith(f":refs/tags/{self.remote.version}")]
        self.assertEqual(pushes, [["git", "push", "origin", f"{original_object}:refs/tags/{self.remote.version}"]])
        self.assertEqual(self.remote.remote_tag, self.remote.merged)


if __name__ == "__main__":
    unittest.main()
