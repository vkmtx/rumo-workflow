if(location.search.includes('dark'))document.body.classList.add('dark');
const MARK='<svg viewBox="0 0 64 64" fill="none"><circle cx="32" cy="32" r="26" stroke="var(--ink)" stroke-width="3.4"/><path d="M32 6v6M58 32h-6M32 58v-6M6 32h6" stroke="var(--ink)" stroke-width="3.4" stroke-linecap="round"/><path d="M47 17 35.5 35.5 28.5 28.5Z" fill="var(--accent)"/><path d="M17 47 28.5 28.5 35.5 35.5Z" fill="var(--ink)"/><circle cx="32" cy="32" r="2.6" fill="var(--paper)"/></svg>';
document.querySelectorAll('.mk').forEach(e=>e.outerHTML=MARK);
