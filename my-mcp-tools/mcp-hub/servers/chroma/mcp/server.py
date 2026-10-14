"""Read-only MCP server exposing the Chroma knowledge base for retrieval.

Ingestion and deletion happen only through the standalone UI (../ui/app.py), never
through this server — agents can search the knowledge base but can't corrupt or wipe it.
"""

import os
from typing import Annotated, Any

import chromadb
from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.exceptions import ToolError
from pydantic import Field

CHROMA_HOST = os.environ.get("CHROMA_HOST", "chroma")
CHROMA_PORT = int(os.environ.get("CHROMA_PORT", "8000"))

mcp = FastMCP(
    "chroma-rag",
    instructions=(
        "A standalone knowledge base of uploaded documents, searched by semantic similarity. "
        "Call chroma_list_collections to see what's available, then chroma_query to search one."
    ),
    host="0.0.0.0",
    port=8000,
    stateless_http=True,
    json_response=True,
)

client = chromadb.HttpClient(host=CHROMA_HOST, port=CHROMA_PORT)


@mcp.tool()
async def chroma_list_collections() -> list[dict[str, Any]]:
    """List the knowledge-base collections available to search, with their document counts."""
    try:
        collections = client.list_collections()
    except Exception:
        raise ToolError("Knowledge base is unavailable. Try again later.")
    return [{"name": c.name, "count": client.get_collection(c.name).count()} for c in collections]


@mcp.tool()
async def chroma_query(
    query: Annotated[str, Field(description="What to search for, in plain language.")],
    collection: Annotated[str, Field(description="Collection name, as returned by chroma_list_collections.")] = "default",
    n_results: Annotated[int, Field(ge=1, le=20)] = 5,
) -> list[dict[str, Any]]:
    """Search a knowledge-base collection for chunks relevant to the query."""
    try:
        coll = client.get_collection(collection)
    except Exception:
        raise ToolError(f"No such collection: {collection!r}. Call chroma_list_collections to see what's available.")
    result = coll.query(query_texts=[query], n_results=n_results)
    documents = (result.get("documents") or [[]])[0]
    metadatas = (result.get("metadatas") or [[]])[0]
    distances = (result.get("distances") or [[]])[0]
    return [
        {"document": doc, "source": (meta or {}).get("source"), "distance": dist}
        for doc, meta, dist in zip(documents, metadatas, distances)
    ]


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
