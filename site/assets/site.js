// agent-playbook overview page: one control, the pause for the wakeup loop.
// Classic script, no module, no network. Without it the loop simply runs and the page reads the same.
(function () {
  var toggle = document.querySelector('[data-loop-toggle]');
  if (!toggle) return;
  var figure = toggle.closest('.loop-figure');
  toggle.addEventListener('click', function () {
    var paused = toggle.getAttribute('aria-pressed') === 'true';
    toggle.setAttribute('aria-pressed', String(!paused));
    toggle.textContent = paused ? 'Pause the loop' : 'Play the loop';
    if (paused) {
      figure.removeAttribute('data-paused');
    } else {
      figure.setAttribute('data-paused', '');
    }
  });
})();
