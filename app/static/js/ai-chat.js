/* static/js/ai-chat.js : load with <script src=".../ai-chat.js" defer> in base.html */
(() => {
  const $ = (id) => document.getElementById(id);
  const sidebar = $('aiSidebar'), toggle = $('aiToggle'), backdrop = $('aiBackdrop');
  const list = $('aiMessages'), form = $('aiForm'), input = $('aiInput'), send = $('aiSend');
  if (!sidebar || !toggle) return;

  const history = [];                                   // [{role:'user'|'assistant', content:'...'}]
  const MAX_HISTORY = 12;

  /* open / close */
  function setOpen(open) {
    sidebar.classList.toggle('is-open', open);
    sidebar.setAttribute('aria-hidden', String(!open));
    toggle.setAttribute('aria-expanded', String(open));
    backdrop.hidden = !open;
    if (open) setTimeout(() => input.focus(), 250); else toggle.focus();
  }
  toggle.addEventListener('click', () => setOpen(!sidebar.classList.contains('is-open')));
  $('aiClose').addEventListener('click', () => setOpen(false));
  backdrop.addEventListener('click', () => setOpen(false));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && sidebar.classList.contains('is-open')) setOpen(false); });

  /* rendering (textContent only, so model output can never inject HTML) */
  function addMessage(role, text, extraClass = '') {
    const row = document.createElement('div');
    row.className = `ai-msg ai-msg--${role === 'user' ? 'user' : 'bot'} ${extraClass}`.trim();
    const bubble = document.createElement('div');
    bubble.className = 'ai-bubble';
    bubble.textContent = text;
    row.appendChild(bubble);
    list.appendChild(row);
    list.scrollTop = list.scrollHeight;
    return row;
  }
  function addTyping() {
    const row = addMessage('bot', '');
    row.querySelector('.ai-bubble').classList.add('ai-typing');
    row.querySelector('.ai-bubble').innerHTML = '<span></span><span></span><span></span>';   // static markup only
    return row;
  }

  /* sending */
  async function ask(text) {
    text = text.trim();
    if (!text) return;
    $('aiSuggestions').hidden = true;
    addMessage('user', text);
    history.push({ role: 'user', content: text });
    input.value = ''; autosize();
    send.disabled = true;
    const typing = addTyping();
    try {
      const res = await fetch(sidebar.dataset.endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'X-CSRFToken': sidebar.dataset.csrf },
        credentials: 'same-origin',
        body: JSON.stringify({ message: text, history: history.slice(-MAX_HISTORY) }),
      });
      const data = await res.json().catch(() => ({}));
      typing.remove();
      if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
      addMessage('bot', data.reply);
      history.push({ role: 'assistant', content: data.reply });
    } catch (err) {
      typing.remove();
      addMessage('bot', err.message || 'Something went wrong. Please try again.', 'ai-msg--error');
    } finally {
      send.disabled = false; input.focus();
    }
  }

  form.addEventListener('submit', (e) => { e.preventDefault(); ask(input.value); });
  input.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); ask(input.value); } });
  function autosize() { input.style.height = 'auto'; input.style.height = Math.min(input.scrollHeight, 120) + 'px'; }
  input.addEventListener('input', autosize);
  document.querySelectorAll('.ai-chip').forEach((c) => c.addEventListener('click', () => ask(c.textContent)));

  $('aiClear').addEventListener('click', () => {
    history.length = 0;
    list.querySelectorAll('.ai-msg:not(:first-child)').forEach((n) => n.remove());
    $('aiSuggestions').hidden = false;
  });
})();