import streamlit as st
import redis
import os
import json
from datetime import datetime, timedelta
import csv
import io

# --- CONFIGURATION ---
REDIS_URL = os.getenv("REDIS_URL", "redis://redis:6379")
r = redis.from_url(REDIS_URL, decode_responses=True)

st.set_page_config(page_title="AI Agent Admin Portal", layout="wide")

# --- SIDEBAR ---
with st.sidebar:
    st.subheader("🔌 AI Gateway")

    gw_url_val = r.get("config:gateway_url") or os.getenv("PORTKEY_GATEWAY_URL", "http://192.168.110.25:8787/v1")
    gw_key_val = r.get("config:gateway_api_key") or ""
    vision_capable_val = r.get("config:vision_capable") == "true"
    mcp_gw_url_val = r.get("config:mcp_gateway_url") or ""
    mcp_slugs_val = r.get("config:mcp_server_slugs") or ""

    gw_url = st.text_input("Gateway URL", value=gw_url_val, help="Base URL of the AI gateway to route all traffic through.")
    gw_api_key = st.text_input("Gateway API Key", value=gw_key_val, type="password")
    vision_capable_input = st.toggle("Vision-capable (supports image/PDF uploads)", value=vision_capable_val, help="The actual model is chosen by the AI Gateway's own routing config — set this to match whether that model can read images/PDFs.")
    mcp_gw_url_input = st.text_input("MCP Gateway URL", value=mcp_gw_url_val, help="Base URL of the AI Gateway's MCP port — often a different host:port than the chat Gateway URL above (e.g. http://192.168.110.161:8788).")
    mcp_slugs_input = st.text_input("MCP Server Slugs (comma-separated)", value=mcp_slugs_val, help="Each slug is an MCP server hosted behind the MCP Gateway URL at {mcp_gateway_url}/{slug}/mcp — its tools are added to every chat request.")

    if st.button("Save AI Gateway Settings"):
        r.set("config:gateway_url", gw_url.strip())
        r.set("config:gateway_api_key", gw_api_key.strip())
        r.set("config:vision_capable", "true" if vision_capable_input else "false")
        r.set("config:mcp_gateway_url", mcp_gw_url_input.strip())
        r.set("config:mcp_server_slugs", mcp_slugs_input.strip())
        st.success("✅ AI Gateway settings saved — takes effect on next request!")

    st.divider()
    if st.button("🗑️ Clear Chat History", help="Clears conversation memory in Redis", use_container_width=True):
        r.delete("chat_history")
        st.toast("Agent's session memory wiped!")

# --- MAIN PAGE ---
st.title("🛡️ AI Agent Admin Portal")
tab1, tab2 = st.tabs(["System Instructions", "Live Session Inspector"])

with tab1:
    st.subheader("Edit System Prompt")
    current_prompt = r.get("config:system_prompt") or "You are a helpful AI assistant."
    new_prompt = st.text_area("Base Instructions", value=current_prompt, height=250)
    if st.button("Save & Hot-Reload"):
        r.set("config:system_prompt", new_prompt)
        st.success("System prompt saved!")
        
with tab2:
    st.subheader("🕵️ Live Session Inspector")
    
    all_keys = r.keys("*")
    chat_keys = [k for k in all_keys if "history" in k or "session" in k]
    
    if st.button("💾 Export All Active Sessions to CSV"):
        if not chat_keys:
            st.warning("No active sessions found in memory.")
        else:
            # Create an in-memory text buffer to hold the CSV data
            output = io.StringIO()
            writer = csv.writer(output)
            
            # Write the CSV Header row
            writer.writerow(["Session ID", "Role", "Content"]) 
            
            # Loop through all active sessions and extract messages
            for key in chat_keys:
                raw_data = r.get(key)
                if raw_data:
                    try:
                        messages = json.loads(raw_data)
                        session_id = key.split(':')[-1]
                        for msg in messages:
                            writer.writerow([
                                session_id,
                                msg.get("role", "unknown"),
                                msg.get("content", "")
                            ])
                    except json.JSONDecodeError:
                        continue # Skip any corrupted keys safely
            
            # Generate the Streamlit download button with the CSV data
            st.download_button(
                label="📥 Click here to Download CSV",
                data=output.getvalue(),
                file_name="active_redis_sessions.csv",
                mime="text/csv",
                type="primary"
            )
            
    st.divider() # Adds a nice visual line below the export button

    if chat_keys:
        # --- FIX 1: Sort the keys deterministically ---
        # Sorting by Redis TTL (reverse) ensures the most recently active sessions are at the top!
        chat_keys.sort(key=lambda k: r.ttl(k), reverse=True)
        
        def format_session(key):
            try:
                ttl = r.ttl(key)
                time_str = "Unknown Time"
                if ttl > 0:
                    last_active = datetime.now() - timedelta(seconds=(3600 - ttl))
                    time_str = last_active.strftime("%m-%d %H:%M:%S")
                
                raw_data = r.get(key)
                if raw_data:
                    messages = json.loads(raw_data)
                    user_msgs = [m.get("content", "") for m in messages if m.get("role") == "user" and m.get("content")]
                    snippet = f'"{user_msgs[-1][:35]}..."' if user_msgs else "No user messages"
                else:
                    snippet = "Empty Session"
                
                short_id = key.split(':')[-1][:8]
                return f"[{time_str}] {snippet} (ID: {short_id})"
            except Exception:
                return key

        # --- FIX 2: Add a strict 'key' parameter to the Streamlit widget ---
        selected_key = st.selectbox(
            "Select Session to Inspect", 
            chat_keys, 
            format_func=format_session,
            key="session_inspector_dropdown"  # Locks the widget state across reruns
        )
        
        session_data = r.get(selected_key)
        
        if session_data:
            try:
                history = json.loads(session_data)
                for msg in history:
                    role = msg.get("role", "unknown")
                    content = msg.get("content", "") or ""
                    
                    if role == "user":
                        st.info(f"👤 **User:** {content}")
                    elif role == "assistant":
                        if "tool_calls" in msg and msg["tool_calls"]:
                             st.warning(f"🤖 **Agent used tool:** {msg['tool_calls'][0]['function']['name']}")
                        else:
                            st.success(f"🤖 **Agent:** {content}")
                    elif role == "tool":
                        with st.expander("🛠️ View Tool Results"):
                            st.code(content)
            except json.JSONDecodeError:
                st.error(f"Key '{selected_key}' contains invalid JSON data.")
    else:
        st.info("No session keys found in Redis. Try sending a message in the Client UI first!")
        if st.button("Refresh Redis Keys"):
            st.rerun()

