// agent-playbook overview page: one control, the pause for the wakeup loop animation.
// Classic script, no module, no network. Without it the loop simply runs and the page reads the same.
// The button keeps one label; aria-pressed says whether the pause is on.
(function () {
  var toggle = document.querySelector('[data-loop-toggle]');
  if (!toggle) return;
  var figure = toggle.closest('.loop-figure');
  toggle.addEventListener('click', function () {
    var paused = toggle.getAttribute('aria-pressed') !== 'true';
    toggle.setAttribute('aria-pressed', String(paused));
    if (paused) {
      figure.setAttribute('data-paused', '');
    } else {
      figure.removeAttribute('data-paused');
    }
  });
})();
