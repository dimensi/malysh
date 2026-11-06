#!/usr/bin/env python3
"""Publish the current feature branch through the project's TestFlight tag workflow."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

REPOSITORY = "dimensi/malysh"
ORIGIN = re.compile(
    r"^(?:git@github\.com:|ssh://git@github\.com/|https://github\.com/)"
    r"dimensi/malysh(?:\.git)?/?$"
)
VERSION = re.compile(r"^v[0-9]+\.[0-9]+\.[0-9]+$")


class ReleaseError(Exception):
    """A release cannot safely proceed or its outcome is unknown."""


def run(command: list[str], *, check: bool = True) -> subprocess.CompletedProcess[str]:
    environment = {**os.environ, "GH_PROMPT_DISABLED": "1", "GIT_TERMINAL_PROMPT": "0"}
    result = subprocess.run(command, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=False, env=environment)
    if check and result.returncode:
        detail = result.stderr.strip() or result.stdout.strip() or f"exit {result.returncode}"
        raise ReleaseError(f"{' '.join(command[:3])}: {detail}")
    return result


def mutation(command: list[str], step: str) -> subprocess.CompletedProcess[str]:
    try:
        return run(command)
    except ReleaseError as error:
        raise ReleaseError(
            f"Не удалось подтвердить шаг «{step}»: {error}. "
            "Проверьте состояние и повторите ту же команду; повторная отправка тега не выполняется."
        ) from error


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["git", *args], check=check)


def gh(*args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return run(["gh", *args], check=check)


def parse_json(result: subprocess.CompletedProcess[str], what: str):
    try:
        return json.loads(result.stdout)
    except (ValueError, TypeError) as error:
        raise ReleaseError(f"Некорректный ответ GitHub: {what}.") from error


def remote_ref(ref: str) -> str | None:
    lines = git("ls-remote", "origin", ref).stdout.splitlines()
    matches = [line.split("\t", 1)[0] for line in lines if line.endswith("\t" + ref)]
    if len(matches) > 1:
        raise ReleaseError(f"Неоднозначная ссылка origin: {ref}.")
    return matches[0] if matches else None


def remote_tag(version: str) -> str | None:
    ref = f"refs/tags/{version}"
    lines = git("ls-remote", "--tags", "origin", ref, ref + "^{}").stdout.splitlines()
    refs = {}
    for line in lines:
        sha, name = line.split("\t", 1)
        refs[name] = sha
    return refs.get(ref + "^{}") or refs.get(ref)


def remote_versions() -> dict[str, str]:
    refs = {}
    for line in git("ls-remote", "--tags", "origin").stdout.splitlines():
        sha, ref = line.split("\t", 1)
        if ref.startswith("refs/tags/"):
            refs[ref.removeprefix("refs/tags/")] = sha
    versions = {}
    for name, sha in refs.items():
        if VERSION.fullmatch(name):
            versions[name] = refs.get(name + "^{}", sha)
    return versions


def local_tag(version: str) -> str | None:
    result = git("rev-parse", "--verify", "--quiet", f"refs/tags/{version}^{{commit}}", check=False)
    if result.returncode not in (0, 1):
        raise ReleaseError("Не удалось проверить локальный тег.")
    return result.stdout.strip() if result.returncode == 0 else None


def release_info(version: str) -> dict | None:
    result = gh("api", f"repos/{REPOSITORY}/releases/tags/{version}", check=False)
    if result.returncode:
        if "HTTP 404" in result.stderr:
            return None
        raise ReleaseError(f"Не удалось проверить GitHub Release: {result.stderr.strip() or 'ошибка GitHub'}")
    value = parse_json(result, "release")
    if not isinstance(value, dict) or value.get("tag_name") != version or not value.get("html_url"):
        raise ReleaseError("GitHub вернул неполные сведения о релизе.")
    if value.get("draft") or value.get("prerelease"):
        raise ReleaseError("Релиз с этим тегом уже существует как черновик или предварительный выпуск.")
    return value


def pulls(branch: str) -> list[dict]:
    result = gh("pr", "list", "--repo", REPOSITORY, "--head", branch, "--base", "main",
                "--state", "all", "--limit", "100", "--json",
                "number,url,state,headRefName,headRefOid,baseRefName,mergeCommit")
    value = parse_json(result, "pull requests")
    if not isinstance(value, list):
        raise ReleaseError("GitHub вернул неполный список pull request.")
    return [item for item in value if item.get("headRefName") == branch and item.get("baseRefName") == "main"]


def pull_view(number: int) -> dict:
    value = parse_json(gh("pr", "view", str(number), "--repo", REPOSITORY, "--json",
                          "number,url,state,headRefName,headRefOid,baseRefName,mergeCommit"), "pull request")
    if not isinstance(value, dict):
        raise ReleaseError("GitHub вернул неполные сведения о pull request.")
    return value


def merge_sha(pull: dict) -> str | None:
    commit = pull.get("mergeCommit")
    return commit.get("oid") if isinstance(commit, dict) else None


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Публикует текущую feature-ветку и запускает TestFlight по тегу.")
    parser.add_argument("version", help="тег версии vX.Y.Z")
    parser.add_argument("--title", help="заголовок PR и GitHub Release")
    parser.add_argument("--notes-file", type=Path, help="готовые заметки GitHub Release")
    args = parser.parse_args(argv)
    if not VERSION.fullmatch(args.version):
        parser.error("версия должна иметь вид vX.Y.Z")
    if args.title is not None and not args.title.strip():
        parser.error("--title не должен быть пустым")
    return args


def publish(args: argparse.Namespace) -> None:
    notes_path = args.notes_file.expanduser().absolute() if args.notes_file else None
    root = Path(git("rev-parse", "--show-toplevel").stdout.strip()).resolve()
    os.chdir(root)
    branch = git("symbolic-ref", "--quiet", "--short", "HEAD", check=False)
    branch_name = branch.stdout.strip()
    if branch.returncode or not branch_name or branch_name == "main":
        raise ReleaseError("Нужна отдельная feature-ветка; выпуск из main или detached HEAD запрещён.")
    origin = git("remote", "get-url", "origin").stdout.strip()
    if not ORIGIN.fullmatch(origin):
        raise ReleaseError("origin должен указывать на github.com/dimensi/malysh без встроенных учётных данных.")
    push_urls = git("remote", "get-url", "--push", "--all", "origin").stdout.splitlines()
    if len(push_urls) != 1 or not ORIGIN.fullmatch(push_urls[0].strip()):
        raise ReleaseError("У origin должен быть ровно один push URL github.com/dimensi/malysh.")
    if git("status", "--porcelain=v1", "--untracked-files=all").stdout:
        raise ReleaseError("Рабочая копия не чистая. Закоммитьте или сохраните изменения перед выпуском.")
    notes = None
    if notes_path:
        try:
            with notes_path.open(encoding="utf-8", newline="") as source:
                notes = source.read()
        except (OSError, UnicodeError) as error:
            raise ReleaseError(f"Не удалось прочитать заметки релиза: {error}.") from error
        if not notes.strip():
            raise ReleaseError("Файл заметок релиза пуст.")

    repo = parse_json(gh("repo", "view", REPOSITORY, "--json", "nameWithOwner,viewerPermission"), "repository")
    if (not isinstance(repo, dict) or repo.get("nameWithOwner", "").lower() != REPOSITORY
            or repo.get("viewerPermission") not in {"ADMIN", "MAINTAIN", "WRITE"}):
        raise ReleaseError("Нет подтверждённого доступа на запись к dimensi/malysh.")
    git("fetch", "--no-tags", "origin", "main")
    main_sha = git("rev-parse", "FETCH_HEAD").stdout.strip()
    head_sha = git("rev-parse", "HEAD").stdout.strip()
    remote_branch = remote_ref(f"refs/heads/{branch_name}")
    existing_tag = remote_tag(args.version)
    existing_release = release_info(args.version)
    local_version = local_tag(args.version)
    existing_pulls = pulls(branch_name)
    open_pulls = [p for p in existing_pulls if str(p.get("state", "")).upper() == "OPEN"]
    merged_pulls = [p for p in existing_pulls if str(p.get("state", "")).upper() == "MERGED"
                    and p.get("headRefOid") == head_sha]
    if len(open_pulls) > 1 or len(merged_pulls) > 1 or (open_pulls and merged_pulls):
        raise ReleaseError("Найдено несколько подходящих PR; проверьте их перед выпуском.")
    if existing_release and not existing_tag:
        raise ReleaseError("GitHub Release существует без проверяемого удалённого тега; остановлено.")
    if existing_tag and (not merged_pulls or merge_sha(merged_pulls[0]) != existing_tag):
        raise ReleaseError(f"Тег {args.version} уже занят другим коммитом или не связан с этой веткой.")
    if local_version and merged_pulls and local_version != merge_sha(merged_pulls[0]):
        raise ReleaseError(f"Локальный тег {args.version} указывает на другой коммит.")
    if local_version and not merged_pulls:
        raise ReleaseError(f"Локальный тег {args.version} уже существует до слияния PR.")
    if remote_branch and remote_branch != head_sha:
        known = git("cat-file", "-e", f"{remote_branch}^{{commit}}", check=False).returncode == 0
        if not known or git("merge-base", "--is-ancestor", remote_branch, head_sha, check=False).returncode:
            raise ReleaseError("Удалённая ветка содержит другие изменения; автоматическая отправка остановлена.")
    if open_pulls and open_pulls[0].get("headRefOid") not in {head_sha, remote_branch}:
        raise ReleaseError("Содержимое открытого PR изменилось; проверьте его перед выпуском.")

    pull = merged_pulls[0] if merged_pulls else (open_pulls[0] if open_pulls else None)
    if not merged_pulls:
        if remote_branch != head_sha:
            mutation(["git", "push", "origin", f"{head_sha}:refs/heads/{branch_name}"], "отправка ветки")
        if pull is None:
            title = args.title or git("log", "-1", "--format=%s").stdout.strip()
            command = ["gh", "pr", "create", "--repo", REPOSITORY, "--base", "main", "--head", branch_name,
                       "--title", title]
            if notes is None:
                result = mutation([*command, "--fill"], "создание PR")
            else:
                with tempfile.TemporaryDirectory(prefix="malysh-release-") as temp:
                    body_path = Path(temp) / "pull-request.md"
                    with body_path.open("w", encoding="utf-8", newline="") as body_file:
                        body_file.write(notes)
                    result = mutation([*command, "--body-file", str(body_path)], "создание PR")
            match = re.search(r"https://github\.com/dimensi/malysh/pull/([0-9]+)", result.stdout)
            if not match:
                raise ReleaseError("PR создан, но его номер не распознан. Проверьте GitHub и повторите команду.")
            pull = pull_view(int(match.group(1)))
        else:
            pull = pull_view(int(pull["number"]))
        if (str(pull.get("state", "")).upper() != "OPEN" or pull.get("headRefOid") != head_sha
                or pull.get("headRefName") != branch_name or pull.get("baseRefName") != "main"):
            raise ReleaseError("PR не совпадает с текущим коммитом и веткой; слияние остановлено.")
        mutation(["gh", "pr", "merge", str(pull["number"]), "--repo", REPOSITORY,
                  "--squash", "--match-head-commit", head_sha], "слияние PR")
        pull = pull_view(int(pull["number"]))
    target = merge_sha(pull)
    if str(pull.get("state", "")).upper() != "MERGED" or pull.get("headRefOid") != head_sha or not target:
        raise ReleaseError("Не удалось подтвердить слитый PR и его исходный коммит; тег не отправлен.")
    git("fetch", "--no-tags", "origin", "main")
    main_sha = git("rev-parse", "FETCH_HEAD").stdout.strip()
    if git("merge-base", "--is-ancestor", target, main_sha, check=False).returncode:
        raise ReleaseError("Коммит слияния не найден в origin/main; тег не отправлен.")
    versions = remote_versions()
    other_versions = sorted(version for version, sha in versions.items() if sha == target and version != args.version)
    if other_versions:
        raise ReleaseError(f"Этот коммит уже выпущен под {', '.join(other_versions)}; новый тег не создан.")
    existing_tag = versions.get(args.version)
    local_version = local_tag(args.version)
    if existing_tag and existing_tag != target:
        raise ReleaseError("Удалённый тег не совпадает с коммитом слияния; выпуск остановлен.")
    if local_version and local_version != target:
        raise ReleaseError("Локальный тег не совпадает с коммитом слияния; выпуск остановлен.")

    if not existing_tag:
        # Another publisher may have created the tag after the version list was read.
        existing_tag = remote_tag(args.version)
        if existing_tag and existing_tag != target:
            raise ReleaseError("Удалённый тег изменился перед созданием; выпуск остановлен.")
    if not existing_tag:
        if not local_version:
            mutation(["git", "tag", "-a", args.version, target, "-m", f"Малыш {args.version[1:]}"], "создание тега")
        tag_object = git("rev-parse", "--verify", f"refs/tags/{args.version}").stdout.strip()
        if (git("cat-file", "-t", tag_object).stdout.strip() != "tag"
                or git("rev-parse", "--verify", f"{tag_object}^{{commit}}").stdout.strip() != target):
            raise ReleaseError("Локальный тег должен быть аннотированным и указывать на коммит слияния.")
        # Check again after local tag creation. A normal push can never overwrite a raced tag.
        existing_tag = remote_tag(args.version)
        if existing_tag and existing_tag != target:
            raise ReleaseError("Удалённый тег изменился перед отправкой; выпуск остановлен.")
        if not existing_tag:
            mutation(["git", "push", "origin", f"{tag_object}:refs/tags/{args.version}"], "отправка тега")
            print(f"Тег {args.version} отправлен; он запускает штатный TestFlight workflow.", flush=True)
    if existing_tag:
        print(f"Тег {args.version} уже существует на нужном коммите; повторный запуск не выполняется.", flush=True)
        if existing_release is None:
            existing_release = release_info(args.version)

    if existing_release:
        release_url = existing_release["html_url"]
        print(f"GitHub Release уже существует: {release_url}", flush=True)
    else:
        command = ["gh", "release", "create", args.version, "--repo", REPOSITORY, "--verify-tag",
                   "--title", args.title or f"Малыш {args.version[1:]}"]
        if notes is None:
            command.append("--generate-notes")
            result = mutation(command, "создание GitHub Release")
        else:
            with tempfile.TemporaryDirectory(prefix="malysh-release-") as temp:
                notes_path = Path(temp) / "notes.md"
                with notes_path.open("w", encoding="utf-8", newline="") as notes_file:
                    notes_file.write(notes)
                result = mutation([*command, "--notes-file", str(notes_path)], "создание GitHub Release")
        release_url = result.stdout.strip()
        if not release_url.startswith(f"https://github.com/{REPOSITORY}/releases/"):
            raise ReleaseError("Не удалось подтвердить URL GitHub Release. Проверьте GitHub и повторите команду.")
        print(f"GitHub Release: {release_url}", flush=True)

    remote_branch = remote_ref(f"refs/heads/{branch_name}")
    if remote_branch == head_sha:
        still_open = [p for p in pulls(branch_name) if str(p.get("state", "")).upper() == "OPEN"]
        if still_open:
            print("Удалённая ветка сохранена: для неё есть открытый PR.", file=sys.stderr)
        else:
            mutation(["git", "push", f"--force-with-lease=refs/heads/{branch_name}:{head_sha}",
                      "origin", f":refs/heads/{branch_name}"], "удаление слитой ветки")
            print("Слитая удалённая ветка удалена.", flush=True)
    elif remote_branch:
        print("Удалённая ветка изменилась и сохранена.", file=sys.stderr)
    print("Сборка и обработка Apple не отслеживаются; доступность TestFlight не подтверждена.", flush=True)
    print("Рабочую копию можно архивировать средствами Codex, если она больше не нужна.", flush=True)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        publish(args)
    except (ReleaseError, OSError, KeyError, ValueError) as error:
        print(f"Выпуск остановлен: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
