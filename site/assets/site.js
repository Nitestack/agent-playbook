// agent-playbook overview page: progressive enhancement only.
// Classic script, zero dependencies. Without JS the page still reads cleanly.
(function () {
  var reducedMotion = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // ── 1. Header elevation + reading progress + scroll-spy ──────────────
  var nav = document.querySelector('.nav');
  var progress = document.querySelector('.nav__progress');
  var navLinks = Array.prototype.slice.call(document.querySelectorAll('.nav__links a[href^="#"]'));
  var sections = navLinks.map(function (a) {
    return document.querySelector(a.getAttribute('href'));
  }).filter(Boolean);

  function updateScroll() {
    var y = window.scrollY || 0;
    if (nav) nav.classList.toggle('is-scrolled', y > 10);
    if (progress) {
      var max = document.documentElement.scrollHeight - window.innerHeight;
      var ratio = max > 0 ? Math.min(1, Math.max(0, y / max)) : 0;
      progress.style.transform = 'scaleX(' + ratio.toFixed(4) + ')';
    }
    var current = null;
    var offset = (nav ? nav.offsetHeight : 72) + 80;
    for (var i = 0; i < sections.length; i++) {
      if (sections[i].getBoundingClientRect().top <= offset) current = sections[i].id;
    }
    navLinks.forEach(function (a) {
      var active = current && a.getAttribute('href') === '#' + current;
      if (active) a.setAttribute('aria-current', 'location');
      else a.removeAttribute('aria-current');
    });
  }
  window.addEventListener('scroll', updateScroll, { passive: true });
  updateScroll();

  // ── 2. One-shot subtle scroll reveals ────────────────────────────────
  if (!reducedMotion && 'IntersectionObserver' in window) {
    document.documentElement.classList.add('js-reveal');
    var revEls = document.querySelectorAll('[data-reveal]');
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) {
          e.target.classList.add('is-visible');
          io.unobserve(e.target);
        }
      });
    }, { threshold: 0.08, rootMargin: '0px 0px -40px 0px' });
    revEls.forEach(function (el) { io.observe(el); });
  }

  // ── 3. Interactive Wakeup Loop (SVG nodes synced with step list) ─────
  var loopToggle = document.querySelector('[data-loop-toggle]');
  var loopFigure = loopToggle ? loopToggle.closest('.loop-figure') : null;
  if (loopToggle && loopFigure) {
    loopToggle.addEventListener('click', function () {
      var paused = loopToggle.getAttribute('aria-pressed') !== 'true';
      loopToggle.setAttribute('aria-pressed', String(paused));
      loopToggle.textContent = paused ? 'Resume animation' : 'Pause animation';
      if (paused) loopFigure.setAttribute('data-paused', '');
      else loopFigure.removeAttribute('data-paused');
    });
  }

  var svgNodes = Array.prototype.slice.call(document.querySelectorAll('[data-loop-step]'));
  var stepItems = Array.prototype.slice.call(document.querySelectorAll('[data-wakeup-step]'));
  function setLoopStep(step) {
    svgNodes.forEach(function (n) {
      var on = n.getAttribute('data-loop-step') === step;
      n.classList.toggle('is-active', on);
      n.setAttribute('aria-pressed', String(on));
    });
    stepItems.forEach(function (li) {
      li.classList.toggle('is-active', li.getAttribute('data-wakeup-step') === step);
    });
  }
  svgNodes.forEach(function (n) {
    n.addEventListener('click', function () { setLoopStep(n.getAttribute('data-loop-step')); });
    n.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault();
        setLoopStep(n.getAttribute('data-loop-step'));
      }
    });
  });
  stepItems.forEach(function (li) {
    li.addEventListener('click', function () { setLoopStep(li.getAttribute('data-wakeup-step')); });
  });
  if (svgNodes.length) setLoopStep('1');

  // ── 4. Skills role filter ────────────────────────────────────────────
  var filterBtns = Array.prototype.slice.call(document.querySelectorAll('[data-skill-filter]'));
  var skillCards = Array.prototype.slice.call(document.querySelectorAll('[data-skill-role]'));
  var skillCount = document.querySelector('[data-skill-count]');
  filterBtns.forEach(function (btn) {
    btn.addEventListener('click', function () {
      var filter = btn.getAttribute('data-skill-filter');
      filterBtns.forEach(function (b) { b.setAttribute('aria-pressed', String(b === btn)); });
      var shown = 0;
      skillCards.forEach(function (card) {
        var roles = (card.getAttribute('data-skill-role') || '').split(' ');
        var match = filter === 'all' || roles.indexOf(filter) !== -1;
        card.classList.toggle('is-hidden', !match);
        if (match) shown++;
      });
      if (skillCount) skillCount.textContent = shown + ' of ' + skillCards.length + ' skills shown';
    });
  });

  // ── 5. Interactive Guard Simulator (dark band) ───────────────────────
  var SIM_DATA = {
    coordinator: [
      {
        label: 'git status --short',
        cmd: 'Bash: git status --short',
        allow: true,
        reason: 'exit 0 — read-only git is allowed in active coordinator shifts.'
      },
      {
        label: 'Edit src/app.ts',
        cmd: 'Edit: /repo/src/app.ts',
        allow: false,
        reason: 'exit 2 — coordinator-guard: Edit is blocked for coordinators; delegate file changes to a worker.'
      },
      {
        label: 'gh pr merge 42',
        cmd: 'Bash: gh pr merge 42',
        allow: false,
        reason: 'exit 2 — coordinator-guard: gh pr merge is not on the coordinator allowlist; hand approved PRs to publish-pr.'
      },
      {
        label: 'delegate_task (draining)',
        cmd: 'mcp__t3-code__delegate_task (state: draining)',
        allow: false,
        reason: 'exit 2 — coordinator-guard: this shift is draining; delegate_task is frozen.'
      },
      {
        label: 't3_thread_send (retired)',
        cmd: 'mcp__t3-code__t3_thread_send (state: retired)',
        allow: false,
        reason: 'exit 2 — coordinator-guard: this coordinator is retired; t3_thread_send is refused. Only teardown and read tools remain.'
      },
      {
        label: 'playbook-registry.sh renew',
        cmd: 'Bash: playbook-registry.sh renew',
        allow: true,
        reason: 'exit 0 — bumps generation, resets started_at, preserves cancel_count and prints the recovery packet.'
      }
    ],
    worker: [
      {
        label: 'Edit worktree/src/a.rs',
        cmd: 'Edit: <worktree>/src/a.rs',
        allow: true,
        reason: 'exit 0 — canonical path resolves inside PLAYBOOK_WORKER_WORKTREE.'
      },
      {
        label: 'Edit ../outside/x',
        cmd: 'Edit: <worktree>/../outside/x',
        allow: false,
        reason: 'exit 2 — worker-guard: Edit may only write inside the worktree (<worktree>); refused: ../outside/x'
      },
      {
        label: 'push origin feature/x',
        cmd: 'Bash: git -C "$PLAYBOOK_WORKER_WORKTREE" push origin feature/x',
        allow: true,
        reason: 'exit 0 — matches bound branch feature/x and is not a protected branch.'
      },
      {
        label: 'push origin main (bound=main)',
        cmd: 'Bash: git -C "$PLAYBOOK_WORKER_WORKTREE" push origin main (PLAYBOOK_WORKER_BRANCH=main)',
        allow: false,
        reason: 'exit 2 — worker-guard: git push must not target main; protected branches are refused before the bound-branch check.'
      },
      {
        label: 'git commit (no -C)',
        cmd: 'Bash: git commit -m "fix"',
        allow: false,
        reason: 'exit 2 — worker-guard: mutating git must name the worktree: git -C "$PLAYBOOK_WORKER_WORKTREE" commit ...'
      }
    ],
    reviewer: [
      {
        label: 'Read snapshot/tree/a.txt',
        cmd: 'Read: <snapshot_root>/tree/a.txt',
        allow: true,
        reason: 'exit 0 — Read inside the immutable, .git-free snapshot root is allowed.'
      },
      {
        label: 'Read snapshot/base/a.txt',
        cmd: 'Read: <snapshot_root>/base/a.txt (--with-base)',
        allow: true,
        reason: 'exit 0 — base/ lives inside the same snapshot_root package.'
      },
      {
        label: 'Read snapshot/leak/secret',
        cmd: 'Read: <snapshot_root>/leak/secret.txt (symlink escape)',
        allow: false,
        reason: 'exit 2 — reviewer-guard: Read may only read inside the review snapshot (<snapshot_root>); symlink escapes are denied.'
      },
      {
        label: 'Bash: ls',
        cmd: 'Bash: ls',
        allow: false,
        reason: 'exit 2 — reviewer-guard: Bash is not allowed for independent reviewers; only Read, Grep and Glob inside the snapshot.'
      }
    ]
  };

  var simTabs = Array.prototype.slice.call(document.querySelectorAll('[data-sim-role]'));
  var simScenariosEl = document.querySelector('[data-sim-scenarios]');
  var simOut = document.querySelector('[data-sim-out]');
  var simBadge = document.querySelector('[data-sim-badge]');
  var simCmd = document.querySelector('[data-sim-cmd]');
  var simReason = document.querySelector('[data-sim-reason]');
  var swapTimer = null;

  function showSimResult(item) {
    if (!simOut || !simBadge || !simCmd || !simReason) return;
    clearTimeout(swapTimer);
    if (!reducedMotion) {
      simOut.classList.add('is-swapping');
      swapTimer = setTimeout(function () {
        applySimResult(item);
        simOut.classList.remove('is-swapping');
      }, 90);
    } else {
      applySimResult(item);
    }
  }

  function applySimResult(item) {
    simBadge.textContent = item.allow ? 'EXIT 0 \u00b7 ALLOWED' : 'EXIT 2 \u00b7 DENIED';
    simBadge.className = 'badge ' + (item.allow ? 'badge--allow' : 'badge--deny');
    simCmd.textContent = item.cmd;
    simReason.textContent = item.reason;
  }

  function renderSimRole(role) {
    var list = SIM_DATA[role] || [];
    simTabs.forEach(function (t) {
      t.setAttribute('aria-selected', String(t.getAttribute('data-sim-role') === role));
    });
    if (!simScenariosEl) return;
    simScenariosEl.innerHTML = '';
    list.forEach(function (item, idx) {
      var btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'sim__btn';
      btn.textContent = item.label;
      btn.setAttribute('aria-pressed', String(idx === 0));
      btn.addEventListener('click', function () {
        Array.prototype.slice.call(simScenariosEl.querySelectorAll('.sim__btn')).forEach(function (b) {
          b.setAttribute('aria-pressed', String(b === btn));
        });
        showSimResult(item);
      });
      simScenariosEl.appendChild(btn);
    });
    if (list[0]) applySimResult(list[0]);
  }

  if (simTabs.length) {
    simTabs.forEach(function (t) {
      t.addEventListener('click', function () { renderSimRole(t.getAttribute('data-sim-role')); });
    });
    renderSimRole('coordinator');
  }

  // ── 6. Registry CLI Tabs in Setup ────────────────────────────────────
  var cliTabs = Array.prototype.slice.call(document.querySelectorAll('[data-cli-tab]'));
  var cliPanels = Array.prototype.slice.call(document.querySelectorAll('[data-cli-panel]'));
  cliTabs.forEach(function (tab) {
    tab.addEventListener('click', function () {
      var id = tab.getAttribute('data-cli-tab');
      cliTabs.forEach(function (t) { t.setAttribute('aria-selected', String(t === tab)); });
      cliPanels.forEach(function (p) { p.hidden = p.getAttribute('data-cli-panel') !== id; });
    });
  });

  // ── 7. Copy-to-clipboard on all code blocks ──────────────────────────
  document.querySelectorAll('[data-copy]').forEach(function (btn) {
    var resetTimer = null;
    btn.addEventListener('click', function () {
      var wrap = btn.closest('.code-wrap') || btn.closest('.term');
      var codeEl = wrap ? wrap.querySelector('code, .term__body') : null;
      if (!codeEl) return;
      var text = codeEl.innerText.replace(/^\$ /gm, '').trim();
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(text).then(function () {
          btn.textContent = 'Copied';
          btn.classList.add('is-copied');
          clearTimeout(resetTimer);
          resetTimer = setTimeout(function () {
            btn.textContent = 'Copy';
            btn.classList.remove('is-copied');
          }, 1600);
        });
      }
    });
  });

  // ── 8. Hero Terminal Replay ──────────────────────────────────────────
  var replayBtn = document.querySelector('[data-term-replay]');
  var termLines = Array.prototype.slice.call(document.querySelectorAll('[data-term-line]'));
  var replayTimers = [];
  function playTerm() {
    replayTimers.forEach(clearTimeout);
    replayTimers = [];
    if (reducedMotion || !termLines.length) return;
    termLines.forEach(function (l) { l.style.opacity = '0'; });
    var delays = [60, 260, 520, 740, 1020];
    termLines.forEach(function (l, i) {
      replayTimers.push(setTimeout(function () { l.style.opacity = '1'; }, delays[i] || (i * 220)));
    });
  }
  if (replayBtn) {
    replayBtn.addEventListener('click', playTerm);
  }
})();
