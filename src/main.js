import {
  STATION_IDS,
  advanceSimulation,
  getStationTierName,
} from './simulation/model.js';

import {
  addVehicle,
  buildDepot,
  buildLine2,
  buildLine3,
  buildLine4,
  buildNextStop,
  buyUpgrade,
  upgradeStation,
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
    'station-required': 'Build this station first.',
    'upgrade-limit': 'This station is already a Hub.',
    'unknown-line': 'Unknown bus line.',
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
  onBuildStop: (lineKey) => {
    const result =
      buildNextStop(
        state,
        lineKey,
      );

    if (result.ok) {
      scheduleSave();

      const stopIndex =
        state[lineKey].stopCount - 1;

      const stationId =
        STATION_IDS[lineKey][
          stopIndex
        ];

      const selection =
        stationId
          ? `station:${stationId}`
          : lineKey;

      renderer.setSelection(
        selection,
      );

      hud.setSelection(
        selection,
      );

      hud.toast(
        state[lineKey].stopCount === 2
          ? `Bus Line ${lineKey.replace('line', '')} opened with one starter bus.`
          : `Line ${lineKey.replace('line', '')} extended to the new stop.`,
      );
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

  onBuildLine: (lineKey) => {
    const builders = {
      line2: buildLine2,
      line3: buildLine3,
      line4: buildLine4,
    };

    const build =
      builders[lineKey];

    const result =
      build
        ? build(state)
        : {
          ok: false,
          reason: 'unknown-line',
        };

    if (result.ok) {
      scheduleSave();

      const stationId =
        STATION_IDS[lineKey][1];

      const selection =
        `station:${stationId}`;

      renderer.setSelection(
        selection,
      );

      hud.setSelection(
        selection,
      );

      hud.toast(
        `Bus Line ${lineKey.replace('line', '')} opened with one starter bus.`,
      );
    } else {
      toastFailure(result);
    }
  },

  onAddVehicle: (lineKey) => {
    const result =
      addVehicle(
        state,
        lineKey,
      );

    if (result.ok) {
      scheduleSave();

      hud.toast(
        `Bus assigned to Line ${lineKey.replace('line', '')}. Headway reduced.`,
      );
    } else {
      toastFailure(result);
    }
  },

  onUpgradeStation: (
    stationId,
  ) => {
    const result =
      upgradeStation(
        state,
        stationId,
      );

    if (result.ok) {
      scheduleSave();

      renderer.setSelection(
        `station:${stationId}`,
      );

      hud.setSelection(
        `station:${stationId}`,
      );

      hud.toast(
        `Station upgraded to ${getStationTierName(state, stationId)}.`,
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

let lastRafAt =
  performance.now();

let frameAccumulatorMs = 0;
let saveAccumulator = 0;
let lastHudRender = 0;

const TARGET_FRAME_INTERVAL_MS =
  1000 / 60;

function frame(now) {
  requestAnimationFrame(frame);

  const rafDeltaMs =
    Math.min(
      100,
      Math.max(
        0,
        now - lastRafAt,
      ),
    );

  lastRafAt = now;
  frameAccumulatorMs +=
    rafDeltaMs;

  if (
    frameAccumulatorMs
    < TARGET_FRAME_INTERVAL_MS
      * 0.98
  ) {
    return;
  }

  const delta = Math.min(
    frameAccumulatorMs / 1000,
    0.1,
  );

  frameAccumulatorMs %=
    TARGET_FRAME_INTERVAL_MS;

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
