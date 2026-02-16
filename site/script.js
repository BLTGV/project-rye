(function () {
  var storageKey = "rye-theme";
  var root = document.documentElement;
  var toggle = document.getElementById("theme-toggle");
  var label = document.getElementById("theme-label");

  function systemPrefersDark() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function getInitialTheme() {
    var stored = window.localStorage.getItem(storageKey);
    if (stored === "light" || stored === "dark") return stored;
    return systemPrefersDark() ? "dark" : "light";
  }

  function setTheme(theme) {
    root.setAttribute("data-theme", theme);
    window.localStorage.setItem(storageKey, theme);
    if (label) {
      label.textContent = theme === "dark" ? "Light mode" : "Dark mode";
    }
  }

  if (toggle) {
    toggle.addEventListener("click", function () {
      var current = root.getAttribute("data-theme") || "light";
      setTheme(current === "dark" ? "light" : "dark");
    });
  }

  setTheme(getInitialTheme());
})();
