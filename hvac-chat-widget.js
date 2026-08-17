/**
 * hvac-chat-widget.js
 * ------------------------------------------------------------------
 * Embeddable chat widget for Clermont Air & Heat (placeholder HVAC
 * business). Same pattern as the Lake America widget — one script tag,
 * builds its own UI, calls your backend, never touches the API key.
 *
 * After running deploy-hvac.ps1, run:
 *   .\update-hvac-widget-endpoint.ps1 -Endpoint "https://your-api-id.execute-api.REGION.amazonaws.com/"
 * ------------------------------------------------------------------
 */

(function () {
  "use strict";

  const CONFIG = {
    businessName: "Clermont Air & Heat",
    launcherIcon: "🔧",
    accentColor: "#c1440e",
    accentLight: "#fbe6d8",
    darkAccent: "#2b2b2b",
    greeting:
      "Hey there! Thanks for reaching out to Clermont Air & Heat. Is this an emergency (no AC/heat) or something we can schedule?",
    apiEndpoint: "https://4zqhnl45ej.execute-api.us-east-1.amazonaws.com/",
  };

  let sessionId = null;
  try {
    sessionId = window.sessionStorage.getItem("hvac-cw-session-id");
  } catch (e) { /* ignore */ }
  if (!sessionId) {
    sessionId =
      (window.crypto && window.crypto.randomUUID && window.crypto.randomUUID()) ||
      "sess-" + Date.now() + "-" + Math.random().toString(16).slice(2);
    try {
      window.sessionStorage.setItem("hvac-cw-session-id", sessionId);
    } catch (e) { /* ignore */ }
  }

  let conversationHistory = [];
  let hasOpenedOnce = false;

  const style = document.createElement("style");
  style.textContent = `
    #hcw-launcher {
      position: fixed; bottom: 24px; right: 24px;
      width: 58px; height: 58px; border-radius: 50%;
      background: ${CONFIG.accentColor}; color: #fff;
      display: flex; align-items: center; justify-content: center;
      font-size: 26px; cursor: pointer; border: none;
      box-shadow: 0 8px 24px rgba(0,0,0,0.3); z-index: 999999;
      font-family: Arial, sans-serif;
    }
    #hcw-window {
      position: fixed; bottom: 96px; right: 24px;
      width: 340px; max-width: 90vw; height: 460px;
      background: #fff; border-radius: 10px;
      box-shadow: 0 20px 50px rgba(0,0,0,0.35);
      display: none; flex-direction: column; overflow: hidden;
      z-index: 999999; font-family: Arial, sans-serif;
      border: 1px solid #ddd;
    }
    #hcw-window.hcw-open { display: flex; }
    #hcw-header {
      background: ${CONFIG.darkAccent}; color: #fff;
      padding: 14px 16px; display: flex; justify-content: space-between;
      align-items: center; font-size: 14px;
    }
    #hcw-header .hcw-dot {
      width: 8px; height: 8px; border-radius: 50%;
      background: ${CONFIG.accentColor}; display: inline-block; margin-right: 8px;
    }
    #hcw-close { cursor: pointer; background: none; border: none; color: #fff; font-size: 18px; }
    #hcw-thread { flex: 1; overflow-y: auto; padding: 14px; display: flex; flex-direction: column; gap: 9px; background: #f7f5f3; }
    .hcw-msg { max-width: 82%; padding: 9px 13px; border-radius: 10px; font-size: 13px; line-height: 1.45; }
    .hcw-msg.hcw-bot { align-self: flex-start; background: ${CONFIG.accentLight}; color: #2b2b2b; }
    .hcw-msg.hcw-user { align-self: flex-end; background: ${CONFIG.accentColor}; color: #fff; }
    #hcw-input-row { display: flex; gap: 8px; padding: 10px; border-top: 1px solid #ddd; background: #fff; }
    #hcw-input { flex: 1; border: 1px solid #ccc; border-radius: 6px; padding: 9px 13px; font-size: 13px; outline: none; }
    #hcw-send { background: ${CONFIG.accentColor}; color: #fff; border: none; border-radius: 6px; padding: 9px 16px; font-size: 12px; cursor: pointer; font-weight: bold; }
    .hcw-typing { display: flex; gap: 4px; padding: 10px 13px; }
    .hcw-typing span { width: 5px; height: 5px; border-radius: 50%; background: #a39a86; display: inline-block; animation: hcwBlink 1.2s infinite ease-in-out; }
    .hcw-typing span:nth-child(2) { animation-delay: 0.2s; }
    .hcw-typing span:nth-child(3) { animation-delay: 0.4s; }
    @keyframes hcwBlink { 0%, 80%, 100% { opacity: 0.3; } 40% { opacity: 1; } }
  `;
  document.head.appendChild(style);

  const launcher = document.createElement("button");
  launcher.id = "hcw-launcher";
  launcher.textContent = CONFIG.launcherIcon;

  const win = document.createElement("div");
  win.id = "hcw-window";
  win.innerHTML = `
    <div id="hcw-header">
      <div><span class="hcw-dot"></span>Chat with ${CONFIG.businessName}</div>
      <button id="hcw-close">✕</button>
    </div>
    <div id="hcw-thread"></div>
    <div id="hcw-input-row">
      <input id="hcw-input" type="text" placeholder="Type a message…" />
      <button id="hcw-send">Send</button>
    </div>
  `;

  document.body.appendChild(launcher);
  document.body.appendChild(win);

  function addMessage(text, cls) {
    const thread = document.getElementById("hcw-thread");
    const div = document.createElement("div");
    div.className = "hcw-msg " + cls;
    div.textContent = text;
    thread.appendChild(div);
    thread.scrollTop = thread.scrollHeight;
  }

  function addBotMessage(text) {
    addMessage(text, "hcw-bot");
    conversationHistory.push({ role: "assistant", content: text });
  }

  function showTyping() {
    const thread = document.getElementById("hcw-thread");
    const div = document.createElement("div");
    div.className = "hcw-msg hcw-bot";
    div.id = "hcw-typing-indicator";
    div.innerHTML = '<div class="hcw-typing"><span></span><span></span><span></span></div>';
    thread.appendChild(div);
    thread.scrollTop = thread.scrollHeight;
  }

  function hideTyping() {
    const el = document.getElementById("hcw-typing-indicator");
    if (el) el.remove();
  }

  async function sendMessage() {
    const input = document.getElementById("hcw-input");
    const text = input.value.trim();
    if (!text) return;
    addMessage(text, "hcw-user");
    conversationHistory.push({ role: "user", content: text });
    input.value = "";
    showTyping();

    try {
      const response = await fetch(CONFIG.apiEndpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          sessionId: sessionId,
          messages: conversationHistory,
        }),
      });
      if (!response.ok) throw new Error("Backend returned " + response.status);
      const data = await response.json();
      hideTyping();
      addBotMessage(data.reply || "Sorry, could you try that again?");
    } catch (err) {
      hideTyping();
      addBotMessage("Sorry, something went wrong — please call us directly.");
    }
  }

  function toggleChat() {
    win.classList.toggle("hcw-open");
    if (win.classList.contains("hcw-open") && !hasOpenedOnce) {
      hasOpenedOnce = true;
      addBotMessage(CONFIG.greeting);
    }
  }

  launcher.addEventListener("click", toggleChat);
  win.querySelector("#hcw-close").addEventListener("click", toggleChat);
  win.querySelector("#hcw-send").addEventListener("click", sendMessage);
  win.querySelector("#hcw-input").addEventListener("keydown", function (e) {
    if (e.key === "Enter") sendMessage();
  });
})();
