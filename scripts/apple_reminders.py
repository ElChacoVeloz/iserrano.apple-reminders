"""Apple Reminders helper for the Omarchy bar widget.

Talks to iCloud Reminders through pyicloud's CloudKit client (CalDAV no longer
carries upgraded Reminders) and prints one line of JSON per call. Every
non-interactive command exits 0 and reports failure in that JSON so a dead
network never looks like a crashed widget.

Commands:
  fetch                       today's + overdue open reminders, all lists
  lists                       reminder lists
  complete <id>               mark a reminder done
  reopen <id>                 undo a completion
  add [--list-id ID] [--no-date] <title>
                              create a reminder (due today, all-day, by default)
  status                      is there a usable session?
  login                       interactive: Apple ID, password, 2FA (terminal)
  logout                      forget password, session and account
"""

import contextlib
import getpass
import json
import os
import shutil
import sys
from datetime import date, datetime, time, timedelta, timezone

DATA_DIR = os.environ.get(
    "APPLE_REMINDERS_DATA",
    os.path.join(os.environ.get("XDG_DATA_HOME", os.path.expanduser("~/.local/share")),
                 "omarchy-apple-reminders"),
)
SESSION_DIR = os.path.join(DATA_DIR, "session")
CONFIG_FILE = os.path.join(DATA_DIR, "config.json")
LISTS_CACHE = os.path.join(DATA_DIR, "lists.json")
KEYRING_SERVICE = "omarchy-apple-reminders"
MAX_TITLE_CHARS = 500


def out(payload):
    sys.stdout.write(json.dumps(payload, separators=(",", ":"), default=str) + "\n")
    sys.stdout.flush()
    sys.exit(0)


def fail(error, hint=""):
    out({"ok": False, "error": error, "hint": str(hint)[:300]})


class HelperError(Exception):
    def __init__(self, kind, hint=""):
        super().__init__(kind)
        self.kind = kind
        self.hint = hint


# --- storage ---------------------------------------------------------------

def private_dir(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def load_config():
    try:
        with open(CONFIG_FILE) as stream:
            data = json.load(stream)
            return data if isinstance(data, dict) else {}
    except (FileNotFoundError, ValueError):
        return {}


def save_config(data):
    private_dir(DATA_DIR)
    tmp = CONFIG_FILE + ".tmp"
    with open(tmp, "w") as stream:
        json.dump(data, stream, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONFIG_FILE)


def secret_keyring():
    # Force the Secret Service (gnome-keyring) backend so the Apple ID
    # password never lands in a plaintext keyring file.
    import keyring
    from keyring.backends import SecretService
    backend = SecretService.Keyring()
    keyring.set_keyring(backend)
    return keyring


def get_password(apple_id):
    try:
        return secret_keyring().get_password(KEYRING_SERVICE, apple_id)
    except Exception as err:
        raise HelperError("keyring", err)


# --- iCloud ---------------------------------------------------------------

def connect():
    apple_id = load_config().get("apple_id", "")
    if not apple_id:
        raise HelperError("no-account")
    password = get_password(apple_id)
    if not password:
        raise HelperError("needs-login", "no password in keyring")
    from pyicloud import PyiCloudService
    from pyicloud.exceptions import (PyiCloud2FARequiredException, PyiCloud2SARequiredException,
                                     PyiCloudFailedLoginException)
    try:
        with contextlib.redirect_stdout(sys.stderr):
            api = PyiCloudService(apple_id, password, cookie_directory=private_dir(SESSION_DIR))
    except (PyiCloud2FARequiredException, PyiCloud2SARequiredException):
        raise HelperError("needs-login", "2FA required")
    except PyiCloudFailedLoginException as err:
        raise HelperError("login-failed", err)
    if api.requires_2fa or api.requires_2sa:
        raise HelperError("needs-login", "2FA required")
    return api


def load_lists_cache():
    try:
        with open(LISTS_CACHE) as stream:
            data = json.load(stream)
            if isinstance(data, dict) and data.get("apple_id") == load_config().get("apple_id"):
                return data
    except (FileNotFoundError, ValueError):
        pass
    return {"apple_id": load_config().get("apple_id"), "token": None, "complete": False, "lists": {}}


def save_lists_cache(cache):
    private_dir(DATA_DIR)
    tmp = LISTS_CACHE + ".tmp"
    with open(tmp, "w") as stream:
        json.dump(cache, stream)
    os.chmod(tmp, 0o600)
    os.replace(tmp, LISTS_CACHE)


def sync_lists(svc, budget=None, progress=None):
    """Bring the cached list set up to date through the zone change feed.

    pyicloud's lists() replays the whole zone history on every call (minutes
    on an old account) because List records are not queryable. Instead keep
    the lists and the sync token on disk, so after the first full pass each
    call only reads what changed. The pass is resumable: the token is saved
    after every page, and `budget` (seconds) bounds a single call.
    """
    from pyicloud.common.cloudkit import CKRecord, CKTombstoneRecord, CKZoneChangesZoneReq
    from pyicloud.services.reminders._constants import _REMINDERS_ZONE

    cache = load_lists_cache()
    started = datetime.now().timestamp()
    pages = 0
    while True:
        response = svc._raw.changes(zone_req=CKZoneChangesZoneReq(
            zoneID=_REMINDERS_ZONE, desiredRecordTypes=["List"], syncToken=cache["token"]))
        more = False
        for zone in response.zones or []:
            for rec in zone.records:
                if isinstance(rec, CKTombstoneRecord):
                    cache["lists"].pop(rec.recordName, None)
                elif isinstance(rec, CKRecord) and rec.recordType == "List":
                    lst = svc._mapper.record_to_list(rec)
                    if lst.deleted:
                        cache["lists"].pop(lst.id, None)
                    else:
                        cache["lists"][lst.id] = {"id": lst.id, "title": lst.title,
                                                  "color": lst.color or "", "isGroup": lst.is_group}
            cache["token"] = zone.syncToken or cache["token"]
            more = more or bool(zone.moreComing)
        pages += 1
        if not more:
            cache["complete"] = True
        save_lists_cache(cache)
        if progress:
            progress(pages, len(cache["lists"]))
        if not more:
            break
        if budget is not None and datetime.now().timestamp() - started > budget:
            break
    return cache


class CachedList:
    def __init__(self, data):
        self.id = data["id"]
        self.title = data["title"]
        self.color = data.get("color", "")


def usable_lists(svc, budget=None, progress=None):
    cache = sync_lists(svc, budget=budget, progress=progress)
    if not cache["complete"]:
        raise HelperError("syncing", "%d listas encontradas hasta ahora" % len(cache["lists"]))
    lists = [CachedList(data) for data in cache["lists"].values() if not data.get("isGroup")]
    return sorted(lists, key=lambda lst: lst.title.lower())


def due_day(reminder):
    """Calendar day a reminder is due on, in the local timezone."""
    due = reminder.due_date
    if due is None:
        return None
    if due.tzinfo is None:
        due = due.replace(tzinfo=timezone.utc)
    if reminder.all_day:
        # All-day dates are a midnight somewhere; round to the nearest UTC
        # midnight so both UTC- and local-midnight storage map to the same day.
        return (due.astimezone(timezone.utc) + timedelta(hours=12)).date()
    return due.astimezone().date()


def shape(reminder, lst, today):
    day = due_day(reminder)
    local = reminder.due_date.astimezone() if reminder.due_date else None
    overdue = day < today
    return {
        "id": reminder.id,
        "content": reminder.title or "(sin título)",
        "notes": (reminder.desc or "")[:300],
        "listId": lst.id,
        "list": lst.title,
        "color": lst.color or "",
        "allDay": bool(reminder.all_day),
        "due": day.isoformat(),
        "time": "" if reminder.all_day or not local else local.strftime("%H:%M"),
        "overdue": overdue,
        "flagged": bool(reminder.flagged),
        "priority": reminder.priority,
        "section": "Vencidos" if overdue else "Hoy",
        "_sort": (0 if overdue else 1, day.isoformat(),
                  "" if reminder.all_day or not local else local.strftime("%H:%M"),
                  (reminder.title or "").lower()),
    }


def cmd_fetch(_argv):
    api = connect()
    svc = api.reminders
    today = date.today()
    items = []
    lists = usable_lists(svc, budget=40)
    for lst in lists:
        result = svc.list_reminders(lst.id, include_completed=False)
        for reminder in result.reminders:
            if reminder.completed or reminder.deleted:
                continue
            day = due_day(reminder)
            if day is None or day > today:
                continue
            items.append(shape(reminder, lst, today))
    items.sort(key=lambda item: item.pop("_sort"))
    if not any(item["overdue"] for item in items):
        for item in items:
            item["section"] = ""
    out({"ok": True, "items": items, "total": len(items),
         "lists": [{"id": lst.id, "title": lst.title} for lst in lists],
         "at": int(datetime.now().timestamp())})


def cmd_lists(_argv):
    svc = connect().reminders
    out({"ok": True, "lists": [{"id": lst.id, "title": lst.title, "color": lst.color or ""}
                               for lst in usable_lists(svc, budget=40)]})


def set_completed(reminder_id, completed):
    svc = connect().reminders
    reminder = svc.get(reminder_id)
    reminder.completed = completed
    reminder.completed_date = datetime.now(timezone.utc) if completed else None
    svc.update(reminder)
    out({"ok": True, "id": reminder_id, "content": reminder.title})


def cmd_complete(argv):
    if len(argv) != 1:
        fail("usage", "complete <id>")
    set_completed(argv[0], True)


def cmd_reopen(argv):
    if len(argv) != 1:
        fail("usage", "reopen <id>")
    set_completed(argv[0], False)


def default_list(lists, wanted):
    if wanted:
        for lst in lists:
            if lst.id == wanted:
                return lst
    for name in ("recordatorios", "reminders", "inbox"):
        for lst in lists:
            if lst.title.strip().lower() == name:
                return lst
    return lists[0] if lists else None


def local_zone_name():
    """IANA name of the system timezone, e.g. America/Chicago."""
    try:
        link = os.path.realpath("/etc/localtime")
        if "/zoneinfo/" in link:
            return link.split("/zoneinfo/", 1)[1]
    except OSError:
        pass
    return None


def cmd_add(argv):
    list_id = ""
    with_date = True
    due_on = date.today()
    at = None
    words = []
    index = 0
    try:
        while index < len(argv):
            arg = argv[index]
            if arg in ("--list-id", "--date", "--time") and index + 1 < len(argv):
                value = argv[index + 1]
                if arg == "--list-id":
                    list_id = value
                elif arg == "--date":
                    due_on = date.fromisoformat(value)
                else:
                    at = time.fromisoformat(value)
                index += 2
                continue
            if arg == "--":
                words.extend(argv[index + 1:])
                break
            if arg == "--no-date":
                with_date = False
            else:
                words.append(arg)
            index += 1
    except ValueError as err:
        fail("bad-date", err)
    title = " ".join(words).strip()
    if not title:
        fail("usage", "add [--list-id ID] [--date YYYY-MM-DD] [--time HH:MM] [--no-date] <title>")
    if len(title) > MAX_TITLE_CHARS:
        fail("text-too-long", len(title))
    svc = connect().reminders
    target = default_list(usable_lists(svc, budget=40), list_id or load_config().get("default_list_id", ""))
    if target is None:
        fail("no-lists")
    if not with_date:
        created = svc.create(list_id=target.id, title=title)
    elif at is None:
        # All-day: midnight UTC of that calendar day.
        due = datetime.combine(due_on, time(0, 0), tzinfo=timezone.utc)
        created = svc.create(list_id=target.id, title=title, due_date=due, all_day=True)
    else:
        due = datetime.combine(due_on, at).astimezone()
        created = svc.create(list_id=target.id, title=title, due_date=due, all_day=False,
                             time_zone=local_zone_name())
    out({"ok": True, "id": created.id, "content": created.title, "list": target.title})


def cmd_status(_argv):
    apple_id = load_config().get("apple_id", "")
    if not apple_id:
        fail("no-account")
    connect()
    out({"ok": True, "appleId": apple_id})


# --- interactive ----------------------------------------------------------

def cmd_login(_argv):
    from pyicloud import PyiCloudService
    from pyicloud.exceptions import PyiCloudFailedLoginException

    config = load_config()
    print("Conectar Apple Reminders (iCloud)\n")
    print("Necesitas tu contraseña real de Apple ID: CloudKit rechaza las")
    print("contraseñas específicas de app. Se guarda en el llavero (gnome-keyring).\n")
    current = config.get("apple_id", "")
    apple_id = input("Apple ID%s: " % (" [%s]" % current if current else "")).strip() or current
    if not apple_id:
        print("Falta el Apple ID.")
        return 1
    password = getpass.getpass("Contraseña: ")
    try:
        api = PyiCloudService(apple_id, password, cookie_directory=private_dir(SESSION_DIR))
    except PyiCloudFailedLoginException as err:
        print("\nApple rechazó el inicio de sesión: %s" % err)
        return 1

    if api.requires_2fa:
        code = input("Código de verificación (6 dígitos) enviado a tus dispositivos: ").strip()
        if not api.validate_2fa_code(code):
            print("Código incorrecto.")
            return 1
        if not api.is_trusted_session:
            api.trust_session()
    elif api.requires_2sa:
        devices = api.trusted_devices
        for i, device in enumerate(devices):
            print("  %d: %s" % (i, device.get("deviceName") or device.get("phoneNumber")))
        device = devices[int(input("Dispositivo para el código: ") or 0)]
        if not api.send_verification_code(device):
            print("No se pudo enviar el código.")
            return 1
        if not api.validate_verification_code(device, input("Código: ").strip()):
            print("Código incorrecto.")
            return 1

    secret_keyring().set_password(KEYRING_SERVICE, apple_id, password)
    config["apple_id"] = apple_id
    save_config(config)

    print("\nConectado. Leyendo tus listas de iCloud (la primera vez puede tardar")
    print("varios minutos si tienes mucho historial; se puede reanudar):")

    def progress(pages, found):
        sys.stdout.write("\r  página %d · %d listas" % (pages, found))
        sys.stdout.flush()

    lists = usable_lists(api.reminders, progress=progress)
    print("\n\nListas:")
    for lst in lists:
        print("  - %s" % lst.title)
    target = default_list(lists, config.get("default_list_id", ""))
    if target:
        print("\nLos recordatorios nuevos irán a: %s" % target.title)
    return 0


def cmd_logout(_argv):
    config = load_config()
    apple_id = config.get("apple_id", "")
    if apple_id:
        try:
            secret_keyring().delete_password(KEYRING_SERVICE, apple_id)
        except Exception:
            pass
    shutil.rmtree(SESSION_DIR, ignore_errors=True)
    for path in (CONFIG_FILE, LISTS_CACHE):
        with contextlib.suppress(FileNotFoundError):
            os.unlink(path)
    out({"ok": True})


COMMANDS = {
    "fetch": cmd_fetch,
    "lists": cmd_lists,
    "complete": cmd_complete,
    "reopen": cmd_reopen,
    "add": cmd_add,
    "status": cmd_status,
    "logout": cmd_logout,
}


def main():
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help"):
        fail("usage", "fetch | lists | complete | reopen | add | status | login | logout")
    command = sys.argv[1]
    if command == "login":
        try:
            sys.exit(cmd_login(sys.argv[2:]) or 0)
        except KeyboardInterrupt:
            sys.exit(130)
    handler = COMMANDS.get(command)
    if handler is None:
        fail("usage", "unknown command %s" % command)
    try:
        handler(sys.argv[2:])
    except HelperError as err:
        fail(err.kind, err.hint)
    except SystemExit:
        raise
    except Exception as err:
        name = type(err).__name__
        if "Connection" in name or "Timeout" in name:
            fail("offline", err)
        fail("helper-crash", "%s: %s" % (name, err))


if __name__ == "__main__":
    main()
