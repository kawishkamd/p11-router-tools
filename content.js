(function () {

  // Detect if we are on a valid page (not login)
  function shouldInject() {
    const url = location.href;
    const hash = location.hash;

    if (!url.includes("index.html")) return false;

    // Not logged in OR on login-status page
    if (!hash || hash === "#" || hash.length < 2) return false;
    if (hash.includes("index_status")) return false;
    if (hash.includes("login")) return false;

    return true;
  }

  function alreadyInjected() {
    return document.getElementById("p11-toolbar");
  }

  function injectToolbar() {
    if (!shouldInject()) return;
    if (alreadyInjected()) return;

    console.log("P11 Toolbar: Injecting...");

    function go(hash) {
      const api = `http://192.168.8.1/reqproc/proc_get?isTest=false&cmd=set_hash&hash=${hash}`;
      fetch(api, { credentials: "include" })
        .catch(() => {})
        .finally(() => {
          const t = Date.now();
          window.location.href = `http://192.168.8.1/index.html?t=${t}#${hash}`;
        });
    }

    const bar = document.createElement("div");
    bar.id = "p11-toolbar";
    bar.innerHTML = `
      <button data-hash="net_lockpci">Cell</button>
      <button data-hash="frequency">Freq</button>
      <button data-hash="ussd">USSD</button>
      <button data-hash="flow_setting">Flow</button>
      <button data-hash="nat">NAT</button>
      <button data-hash="l2tp">L2TP</button>
      <button data-hash="unlock">Unlock</button>
    `;

    document.body.appendChild(bar);

    bar.addEventListener("click", (e) => {
      if (e.target.tagName.toLowerCase() === "button") {
        go(e.target.dataset.hash);
      }
    });
  }

  // Inject once on startup
  injectToolbar();

  // Re-inject when hash changes
  window.addEventListener("hashchange", () => {
    console.log("P11 Toolbar: Hash changed → reinject");
    injectToolbar();
  });

  // Detect router replacing DOM
  const observer = new MutationObserver(() => {
    if (!alreadyInjected() && shouldInject()) {
      injectToolbar();
    }
  });

  observer.observe(document.body, { childList: true, subtree: true });

})();
