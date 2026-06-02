import json
import ssl
from urllib.parse import urlencode
from urllib.request import Request, urlopen


SSL_CONTEXT = ssl._create_unverified_context()


def login(server, user, password):
    server = server.rstrip("/")
    data = json.dumps({"username": user, "password": password}).encode()
    req = Request(
        f"{server}/login",
        data=data,
        headers={
            "Content-Type": "application/json",
            "x-return-tokens": "true",
        },
        method="POST",
    )
    body = json.loads(urlopen(req, context=SSL_CONTEXT).read().decode())
    token = (
        body.get("accessToken")
        or body.get("user", {}).get("accessToken")
        or body.get("token")
        or body.get("user", {}).get("token")
    )
    if not token:
        raise RuntimeError("login worked but no token was returned")
    return server, token


def get(server, token, path):
    req = Request(
        f"{server}{path}",
        headers={"Authorization": f"Bearer {token}"},
        method="GET",
    )
    return json.loads(urlopen(req, context=SSL_CONTEXT).read().decode())


def list_libraries(server, token):
    body = get(server, token, "/api/libraries")
    libraries = body.get("libraries", body) if isinstance(body, dict) else body
    return libraries or []


def pull_items(server, token, library_id, page=1, limit=100):
    query = urlencode({"limit": limit, "page": page})
    body = get(server, token, f"/api/libraries/{library_id}/items?{query}")
    items = []
    if isinstance(body, dict):
        items = body.get("results") or body.get("items") or body.get("libraryItems") or []
    elif isinstance(body, list):
        items = body

    if len(items) < limit:
        return items
    return items + pull_items(server, token, library_id, page + 1, limit)


def list_all_books(server, user, password):
    server, token = login(server, user, password)
    books = []
    for library in list_libraries(server, token):
        library_id = library.get("id") or library.get("_id")
        media_type = (library.get("mediaType") or library.get("type") or "").lower()
        if library_id and ("book" in media_type or not media_type):
            books.extend(pull_items(server, token, library_id))
    return books


def list_finished_books(server, user, password):
    server, token = login(server, user, password)
    progress_body = get(server, token, "/api/me")
    progress_list = progress_body.get("mediaProgress", [])
    finished_ids = set()
    for item in progress_list:
        progress = item.get("progress", 0)
        if item.get("isFinished") is True or float(progress or 0) >= 0.99:
            finished_ids.add(item.get("libraryItemId") or item.get("id"))

    books = []
    for library in list_libraries(server, token):
        library_id = library.get("id") or library.get("_id")
        media_type = (library.get("mediaType") or library.get("type") or "").lower()
        if library_id and ("book" in media_type or not media_type):
            books.extend(pull_items(server, token, library_id))
    return [
        book
        for book in books
        if (book.get("id") or book.get("_id")) in finished_ids
    ]


if __name__ == "__main__":
    server = "https://your-audiobookshelf-server.com"
    user = "your-user"
    password = "your-password"

    all_books = list_all_books(server, user, password)
    print("all books:", len(all_books))
    for book in all_books:
        media = book.get("media", {})
        metadata = media.get("metadata", {})
        print("-", metadata.get("title") or book.get("title") or book.get("id"))

    finished_books = list_finished_books(server, user, password)
    print("\nfinished books:", len(finished_books))
    for book in finished_books:
        media = book.get("media", {})
        metadata = media.get("metadata", {})
        print("-", metadata.get("title") or book.get("title") or book.get("id"))
