import {
  advanceSimulation,
} from './simulation/model.js';

import {
  addVehicle,
  buildDepot,
  buildLine2,
  buildNextStop,
  buyUpgrade,
  setSimulationSpeed,
} from './simulation/actions.js';

import {
  clearSave,
  loadState,
  saveState,
} from './persistence/storage.js';

import {
  ThreeTransportRenderer,
} from './render/threeTransportRenderer.js';

import {
  Hud,
} from './ui/hud.js';

const canvas =
  document.querySelector('#transport-canvas');

let state = loadState();
let hud;
let resetInProgress = false;
let saveScheduled = false;

const scheduleSave = () => {
  if (
    resetInProgress
    || saveScheduled
  ) {
    return;
  }

  saveScheduled = true;

  const commit = () => {
    saveScheduled = false;

    if (!resetInProgress) {
      saveState(state);
    }
  };

  if (
    typeof window.requestIdleCallback
    === 'function'
  ) {
    window.requestIdleCallback(
      commit,
      {
        timeout: 1200,
      },
    );

    return;
  }

  window.setTimeout(
    commit,
    0,
  );
};

const toastFailure = (result) => {
  const messages = {
    'insufficient-funds': 'Not enough funds.',
    'line-required': 'That line is not open yet.',
    'depot-required': 'Build the Bus Depot first.',
    'progress-required': 'This has not been unlocked yet.',
    'stop-limit': 'No more stops are available in this bus-era prototype.',
    'fleet-limit': 'Fleet limit reached for this line.',
    'garage-full': 'The depot garage is full. Expand it first.',
    'already-built': 'That infrastructure is already built.',
  };

  hud.toast(
    messages[result.reason]
      ?? 'Action unavailable.',
  );
};

const renderer =
  new ThreeTransportRenderer(
    canvas,
    {
      onSelectionChanged: (selection) => {
        hud?.setSelection(selection);
      },
    },
  );

hud = new Hud({
  onBuildStop1: () => {
    const result =
      buildNextStop(state, 'line1');

    if (result.ok) {
      scheduleSave();
      renderer.setSelection('line1');
      hud.setSelection('line1');

      hud.toast(
        state.line1.stopCount === 2
          ? 'Bus Line 1 opened with one starter bus.'
          : 'Line 1 extended to the new stop.',
      );
    } else {
      toastFailure(result);
    }
  },

  onBuildStop2: () => {
    const result =
      buildNextStop(state, 'line2');

    if (result.ok) {
      scheduleSave();
      renderer.setSelection('line2');
      hud.setSelection('line2');
      hud.toast('Line 2 extended to the new stop.');
    } else {
      toastFailure(result);
    }
  },

  onBuildDepot: () => {
    const result =
      buildDepot(state);

    if (result.ok) {
      scheduleSave();
      renderer.setSelection('depot');
      hud.setSelection('depot');
      hud.toast(
        'Bus Depot opened. Additional buses can now be purchased.',
      );
    } else {
      toastFailure(result);
    }
  },

  onBuildLine2: () => {
    const result =
      buildLine2(state);

    if (result.ok) {
      scheduleSave();
      renderer.setSelection('line2');
      hud.setSelection('line2');
      hud.toast(
        'Bus Line 2 opened with one starter bus.',
      );
    } else {
      toastFailure(result);
    }
  },

  onAddVehicle1: () => {
    const result =
      addVehicle(state, 'line1');

    if (result.ok) {
      scheduleSave();
      hud.toast(
        'Bus assigned to Line 1. Headway reduced.',
      );
    } else {
      toastFailure(result);
    }
  },

  onAddVehicle2: () => {
    const result =
      addVehicle(state, 'line2');

    if (result.ok) {
      scheduleSave();
      hud.toast(
        'Bus assigned to Line 2. Headway reduced.',
      );
    } else {
      toastFailure(result);
    }
  },

  onUpgrade: (type) => {
    const result =
      buyUpgrade(state, type);

    if (result.ok) {
      scheduleSave();
      hud.toast('Upgrade purchased.');
    } else {
      toastFailure(result);
    }
  },

  onSpeed: (speed) => {
    setSimulationSpeed(state, speed);
    scheduleSave();
  },

  onInspectorClose: () => {
    renderer.setSelection(null);
  },

  onReset: () => {
    const confirmed =
      window.confirm(
        'Reset the entire game and start again from the first stop? This cannot be undone.',
      );

    if (!confirmed) return;

    resetInProgress = true;
    clearSave();
    location.reload();
  },
});

let last = performance.now();
let saveAccumulator = 0;
let lastHudRender = 0;

function frame(now) {
  const delta = Math.min(
    (now - last) / 1000,
    0.1,
  );

  last = now;

  advanceSimulation(
    state,
    delta,
  );

  renderer.render(
    state,
    delta,
  );

  if (
    now - lastHudRender
    >= 100
  ) {
    hud.render(state);
    lastHudRender = now;
  }

  saveAccumulator += delta;

  if (saveAccumulator >= 12) {
    scheduleSave();
    saveAccumulator = 0;
  }

  requestAnimationFrame(frame);
}

window.addEventListener(
  'beforeunload',
  () => {
    if (!resetInProgress) {
      saveState(state);
    }
  },
);

hud.render(state);
requestAnimationFrame(frame);
