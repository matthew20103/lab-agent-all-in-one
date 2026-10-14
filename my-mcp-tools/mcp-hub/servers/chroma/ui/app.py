"""Standalone admin UI for the Chroma knowledge base: create collections, upload documents
(parsed, chunked and embedded here), browse/delete chunks. Independent of chroma-mcp and
mcp-proxy — talks to the `chroma` container directly. Protected by Caddy basicauth at the
edge (see edge-proxy/Caddyfile), not by any login of its own.
"""

import io
import os
import uuid
from typing import Annotated

import chromadb
import docx
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from pypdf import PdfReader
from starlette.requests import Request

CHROMA_HOST = os.environ.get("CHROMA_HOST", "chroma")
CHROMA_PORT = int(os.environ.get("CHROMA_PORT", "8000"))
CHUNK_SIZE = 1000
CHUNK_OVERLAP = 150
PAGE_SIZE = 50
SUPPORTED_EXTENSIONS = (".pdf", ".docx", ".txt", ".md")

app = FastAPI(title="Chroma Knowledge Base")
templates = Jinja2Templates(directory=os.path.join(os.path.dirname(__file__), "templates"))
client = chromadb.HttpClient(host=CHROMA_HOST, port=CHROMA_PORT)


def extract_text(filename: str, data: bytes) -> str:
    ext = filename.lower().rsplit(".", 1)[-1] if "." in filename else ""
    if ext == "pdf":
        reader = PdfReader(io.BytesIO(data))
        return "\n".join(page.extract_text() or "" for page in reader.pages)
    if ext == "docx":
        document = docx.Document(io.BytesIO(data))
        return "\n".join(p.text for p in document.paragraphs)
    if ext in ("txt", "md"):
        return data.decode("utf-8", errors="replace")
    raise ValueError(f"Unsupported file type: .{ext}")


def chunk_text(text: str, size: int = CHUNK_SIZE, overlap: int = CHUNK_OVERLAP) -> list[str]:
    text = text.strip()
    if not text:
        return []
    chunks = []
    start = 0
    while start < len(text):
        end = start + size
        chunk = text[start:end].strip()
        if chunk:
            chunks.append(chunk)
        if end >= len(text):
            break
        start = end - overlap
    return chunks


@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    collections = [
        {"name": c.name, "count": client.get_collection(c.name).count()}
        for c in client.list_collections()
    ]
    return templates.TemplateResponse(request, "index.html", {"collections": collections})


@app.post("/collections")
async def create_collection(name: Annotated[str, Form()]):
    name = name.strip()
    if not name:
        raise HTTPException(400, "Collection name is required.")
    client.get_or_create_collection(name)
    return RedirectResponse(f"/collections/{name}", status_code=303)


@app.get("/collections/{name}", response_class=HTMLResponse)
async def view_collection(request: Request, name: str, offset: int = 0):
    try:
        coll = client.get_collection(name)
    except Exception:
        raise HTTPException(404, f"No such collection: {name}")
    total = coll.count()
    page = coll.get(limit=PAGE_SIZE, offset=offset, include=["documents", "metadatas"])
    documents = [
        {
            "id": doc_id,
            "source": (meta or {}).get("source", "?"),
            "chunk_index": (meta or {}).get("chunk_index", "?"),
            "snippet": (doc or "")[:200],
        }
        for doc_id, doc, meta in zip(page["ids"], page["documents"], page["metadatas"])
    ]
    return templates.TemplateResponse(
        request,
        "collection.html",
        {
            "name": name,
            "documents": documents,
            "total": total,
            "offset": offset,
            "page_size": PAGE_SIZE,
            "supported_extensions": ", ".join(SUPPORTED_EXTENSIONS),
        },
    )


@app.post("/collections/{name}/upload")
async def upload(name: str, file: UploadFile = File(...)):
    try:
        coll = client.get_collection(name)
    except Exception:
        raise HTTPException(404, f"No such collection: {name}")

    filename = file.filename or "upload"
    if not filename.lower().endswith(SUPPORTED_EXTENSIONS):
        raise HTTPException(400, f"Unsupported file type. Allowed: {', '.join(SUPPORTED_EXTENSIONS)}")

    data = await file.read()
    try:
        text = extract_text(filename, data)
    except Exception as exc:
        raise HTTPException(400, f"Couldn't read {filename}: {exc}")

    chunks = chunk_text(text)
    if not chunks:
        raise HTTPException(400, f"No text extracted from {filename}.")

    coll.add(
        ids=[str(uuid.uuid4()) for _ in chunks],
        documents=chunks,
        metadatas=[{"source": filename, "chunk_index": i} for i in range(len(chunks))],
    )
    return RedirectResponse(f"/collections/{name}", status_code=303)


@app.post("/collections/{name}/documents/{doc_id}/delete")
async def delete_document(name: str, doc_id: str):
    try:
        coll = client.get_collection(name)
    except Exception:
        raise HTTPException(404, f"No such collection: {name}")
    coll.delete(ids=[doc_id])
    return RedirectResponse(f"/collections/{name}", status_code=303)


@app.post("/collections/{name}/delete")
async def delete_collection(name: str, confirm_name: Annotated[str, Form()]):
    if confirm_name.strip() != name:
        raise HTTPException(400, "Typed name doesn't match — collection not deleted.")
    client.delete_collection(name)
    return RedirectResponse("/", status_code=303)
