import {
  ECONOMY,
  LINE_KEYS,
  STATION_IDS,
  STATION_UPGRADE,
  STOP_NAMES,
  TRANSPORT_MODES,
  canBuildDepot,
  canUnlockLine2,
  canUnlockLine3,
  canUnlockLine4,
  getAverageWaitMinutes,
  getBottleneck,
  getDeliveredPassengersPpm,
  getGarageUsed,
  getLastFareEventValue,
  getLineCapacityPpm,
  getLineDemandPpm,
  getLineFrequencyPerHour,
  getLineHeadwayMinutes,
  getLineOnboardPassengers,
  getLineOneWayMinutes,
  getLineWaitingPassengers,
  getNextStopCost,
  getStationDemandPpm,
  getStationLevel,
  getStationName,
  getStationServedLines,
  getStationTierName,
  getStationUpgradeCost,
  getStationWaitingCapacity,
  getStationWaitingPassengers,
  getStopDemandPpm,
  getUpgradeCost,
  getVehiclePurchaseCost,
  isStationBuilt,
} from '../simulation/model.js';

const compact = (value) => {
  if (value >= 1_000_000) {
    return `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 0 : 1)}m`;
  }

  if (value >= 1_000) {
    return `${(value / 1_000).toFixed(value >= 10_000 ? 0 : 1)}k`;
  }

  return value.toFixed(value < 100 ? 1 : 0);
};

const money = (value) => `$${compact(value)}`;

const formatMinutes = (value) =>
  Number.isFinite(value)
    ? `${value.toFixed(value < 10 ? 1 : 0)} min`
    : '—';

export class Hud {
  constructor({
    onBuildStop,
    onBuildDepot,
    onBuildLine,
    onAddVehicle,
    onUpgradeStation,
    onUpgrade,
    onSpeed,
    onReset,
    onInspectorClose,
  }) {
    this.handlers = {
      onBuildStop,
      onBuildDepot,
      onBuildLine,
      onAddVehicle,
      onUpgradeStation,
      onUpgrade,
    };

    this.selection = null;
    this.inspectorStructureKey = null;

    this.el = {
      money: document.querySelector('#money-value'),
      throughput: document.querySelector('#throughput-value'),
      income: document.querySelector('#income-value'),
      objective: document.querySelector('#objective-text'),
      progress: document.querySelector('#progress-text'),

      inspector: document.querySelector('#inspector-panel'),
      inspectorClose: document.querySelector('#inspector-close'),
      inspectorKicker: document.querySelector('#inspector-kicker'),
      inspectorTitle: document.querySelector('#inspector-title'),
      inspectorSubtitle: document.querySelector('#inspector-subtitle'),
      inspectorStats: document.querySelector('#inspector-stats'),
      inspectorActions: document.querySelector('#inspector-actions'),

      toast: document.querySelector('#toast'),
      reset: document.querySelector('#reset-button'),
    };

    this.el.inspectorClose.addEventListener(
      'click',
      () => {
        this.selection = null;
        this.inspectorStructureKey = null;
        onInspectorClose?.();
        this.#syncInspector();
      },
    );

    this.el.inspectorActions.addEventListener(
      'click',
      (event) => {
        const button =
          event.target.closest('[data-command]');

        if (!button || button.disabled) return;

        const command =
          button.dataset.command;

        if (command === 'build-stop') {
          this.handlers.onBuildStop(
            button.dataset.line,
          );
        } else if (command === 'build-depot') {
          this.handlers.onBuildDepot();
        } else if (command === 'build-line') {
          this.handlers.onBuildLine(
            button.dataset.line,
          );
        } else if (command === 'add-vehicle') {
          this.handlers.onAddVehicle(
            button.dataset.line,
          );
        } else if (command === 'upgrade-station') {
          this.handlers.onUpgradeStation(
            button.dataset.station,
          );
        } else if (command === 'upgrade') {
          this.handlers.onUpgrade(
            button.dataset.type,
          );
        }
      },
    );

    const pauseButton =
      document.querySelector(
        '.speed-box > [data-speed="0"]',
      );

    pauseButton?.addEventListener(
      'click',
      () => onSpeed(
        this.currentSpeed === 0
          ? 1
          : 0,
      ),
    );

    document.querySelectorAll(
      '.speed-popover [data-speed]',
    ).forEach((button) => {
      button.addEventListener(
        'click',
        () => onSpeed(
          Number(button.dataset.speed),
        ),
      );
    });

    this.el.reset.addEventListener(
      'click',
      onReset,
    );
  }

  setSelection(selection) {
    if (selection !== this.selection) {
      this.inspectorStructureKey = null;
    }

    this.selection = selection;
    this.#syncInspector();
  }

  render(state) {
    this.currentSpeed =
      state.simulationSpeed;

    const delivered =
      getDeliveredPassengersPpm(state);

    const lastFare =
      getLastFareEventValue(state);

    this.el.money.textContent =
      compact(state.money);

    this.el.throughput.textContent =
      `${delivered.toFixed(1)} pax/min`;

    this.el.income.textContent =
      lastFare > 0
        ? `LAST +${compact(lastFare)}`
        : 'LAST —';

    if (this.el.progress) {
      this.el.progress.textContent =
        this.#getProgressText(state);
    }

    this.#renderInspector(state);
    this.#renderObjective(state);
    this.#syncInspector();

    document.querySelectorAll(
      '[data-speed]',
    ).forEach((button) => {
      button.classList.toggle(
        'active',
        Number(button.dataset.speed)
          === state.simulationSpeed,
      );
    });

    const pauseButton =
      document.querySelector(
        '.speed-box > [data-speed="0"]',
      );

    if (pauseButton) {
      pauseButton.textContent =
        state.simulationSpeed === 0
          ? '▶'
          : 'Ⅱ';
    }
  }

  #syncInspector() {
    this.el.inspector.classList.toggle(
      'hidden',
      !this.selection,
    );
  }

  #renderInspector(state) {
    if (!this.selection) return;

    const view =
      this.#getInspectorView(
        state,
        this.selection,
      );

    if (!view) {
      this.selection = null;
      this.inspectorStructureKey = null;
      this.#syncInspector();
      return;
    }

    const structureKey =
      JSON.stringify({
        selection: this.selection,
        stats: view.stats.map(
          (stat) => stat.label,
        ),
        actions: view.actions.map(
          (action) => [
            action.command,
            action.type ?? '',
            action.lineKey ?? '',
            action.stationId ?? '',
            action.title,
            action.detail,
          ],
        ),
      });

    if (
      structureKey
      !== this.inspectorStructureKey
    ) {
      this.inspectorStructureKey =
        structureKey;

      this.#buildInspectorStructure(view);
    }

    this.el.inspectorKicker.textContent =
      view.kicker;

    this.el.inspectorTitle.textContent =
      view.title;

    this.el.inspectorSubtitle.textContent =
      view.subtitle;

    const statRows = [
      ...this.el.inspectorStats.children,
    ];

    view.stats.forEach(
      (stat, index) => {
        const row = statRows[index];
        if (!row) return;

        const value =
          row.querySelector('strong');

        if (!value) return;

        value.textContent = stat.value;
        value.className =
          stat.className ?? '';
      },
    );

    const actionButtons = [
      ...this.el.inspectorActions
        .querySelectorAll('[data-command]'),
    ];

    view.actions.forEach(
      (action, index) => {
        const button =
          actionButtons[index];

        if (!button) return;

        button.disabled =
          Boolean(action.disabled);

        const price =
          button.querySelector('.buy-pill');

        if (price) {
          price.textContent =
            action.costLabel;
        }
      },
    );
  }

  #buildInspectorStructure(view) {
    this.el.inspectorStats.replaceChildren();

    for (const stat of view.stats) {
      const row =
        document.createElement('div');

      row.className = 'inspector-stat';

      const label =
        document.createElement('span');

      label.textContent = stat.label;

      const value =
        document.createElement('strong');

      row.append(label, value);
      this.el.inspectorStats.append(row);
    }

    this.el.inspectorActions.replaceChildren();

    for (const action of view.actions) {
      const button =
        document.createElement('button');

      button.type = 'button';
      button.className = 'inspector-action';
      button.dataset.command =
        action.command;

      if (action.type) {
        button.dataset.type =
          action.type;
      }

      if (action.lineKey) {
        button.dataset.line =
          action.lineKey;
      }

      if (action.stationId) {
        button.dataset.station =
          action.stationId;
      }

      const copy =
        document.createElement('span');

      copy.className =
        'inspector-action-copy';

      const title =
        document.createElement('strong');

      title.textContent = action.title;

      const detail =
        document.createElement('small');

      detail.textContent =
        action.detail;

      copy.append(title, detail);

      const price =
        document.createElement('span');

      price.className = 'buy-pill';

      button.append(copy, price);

      this.el.inspectorActions.append(
        button,
      );
    }
  }

  #getInspectorView(state, selection) {
    if (
      selection.startsWith(
        'station:',
      )
    ) {
      return this.#getStationView(
        state,
        selection.slice(
          'station:'.length,
        ),
      );
    }

    if (
      selection.startsWith(
        'futureStop:',
      )
    ) {
      return this.#getFutureStopView(
        state,
        selection.slice(
          'futureStop:'.length,
        ),
      );
    }

    if (
      selection.startsWith(
        'futureLine:',
      )
    ) {
      return this.#getFutureLineView(
        state,
        selection.slice(
          'futureLine:'.length,
        ),
      );
    }

    if (
      LINE_KEYS.includes(
        selection,
      )
    ) {
      return this.#getLineView(
        state,
        selection,
      );
    }

    if (selection === 'futureDepot') {
      return {
        kicker: 'NEW FACILITY',
        title: 'Bus Depot',
        subtitle:
          'Unlocked after reaching the third stop',
        stats: [
          {
            label: 'STARTING SLOTS',
            value: '4 buses',
          },
          {
            label: 'PURPOSE',
            value: 'FLEET',
          },
          {
            label: 'LINE 1 FLEET',
            value:
              `${state.line1.fleetCount} bus`,
          },
        ],
        actions: [
          {
            command: 'build-depot',
            title: 'Build Bus Depot',
            detail:
              'Unlocks purchasing additional physical buses',
            costLabel: money(
              ECONOMY.depotBuildCost,
            ),
            disabled:
              state.money
              < ECONOMY.depotBuildCost,
          },
        ],
      };
    }

    if (selection === 'depot') {
      return this.#getDepotView(
        state,
      );
    }

    return null;
  }

  #getStationView(
    state,
    stationId,
  ) {
    if (
      !isStationBuilt(
        state,
        stationId,
      )
    ) {
      return null;
    }

    const level =
      getStationLevel(
        state,
        stationId,
      );

    const tier =
      getStationTierName(
        state,
        stationId,
      );

    const servedLines =
      getStationServedLines(
        state,
        stationId,
      );

    const waiting =
      getStationWaitingPassengers(
        state,
        stationId,
      );

    const capacity =
      getStationWaitingCapacity(
        state,
        stationId,
      );

    const demand =
      getStationDemandPpm(
        state,
        stationId,
      );

    const lineLabel =
      servedLines.length > 0
        ? servedLines
          .map(
            (lineKey) =>
              `L${lineKey.replace('line', '')}`,
          )
          .join(' · ')
        : 'NOT IN SERVICE';

    const actions = [];

    if (
      level
      < STATION_UPGRADE.maxLevel
    ) {
      const nextTier =
        STATION_UPGRADE
          .tierNames[
            level + 1
          ];

      actions.push({
        command:
          'upgrade-station',
        stationId,
        title:
          `Upgrade to ${nextTier}`,
        detail:
          'More waiting space, slightly faster dwell and a larger local catchment',
        costLabel:
          money(
            getStationUpgradeCost(
              state,
              stationId,
            ),
          ),
        disabled:
          state.money
          < getStationUpgradeCost(
            state,
            stationId,
          ),
      });
    }

    return {
      kicker: 'STATION',
      title:
        getStationName(
          stationId,
        ),
      subtitle:
        `${tier} · ${lineLabel}`,
      stats: [
        {
          label: 'LEVEL',
          value:
            `${level} / ${STATION_UPGRADE.maxLevel}`,
        },
        {
          label: 'SERVES',
          value:
            lineLabel,
        },
        {
          label: 'WAITING',
          value:
            `${waiting.toFixed(
              waiting < 10 ? 1 : 0,
            )} pax`,
          className:
            waiting > capacity * 0.7
              ? 'metric-warning'
              : '',
        },
        {
          label: 'QUEUE CAP.',
          value:
            `${capacity} pax / line`,
        },
        {
          label: 'LOCAL DEMAND',
          value:
            servedLines.length > 0
              ? `${demand.toFixed(1)} pax/min`
              : '—',
        },
      ],
      actions,
    };
  }

  #getFutureStopView(
    state,
    lineKey,
  ) {
    if (
      !LINE_KEYS.includes(
        lineKey,
      )
    ) {
      return null;
    }

    const line =
      state[lineKey];

    const index =
      line.stopCount;

    const name =
      STOP_NAMES[lineKey]?.[
        index
      ];

    const stationId =
      STATION_IDS[lineKey]?.[
        index
      ];

    if (
      !name
      || !stationId
    ) {
      return null;
    }

    const lineNumber =
      lineKey.replace(
        'line',
        '',
      );

    const existingStation =
      isStationBuilt(
        state,
        stationId,
      );

    const cost =
      getNextStopCost(
        state,
        lineKey,
      );

    return {
      kicker: 'EXPANSION',
      title: name,
      subtitle:
        existingStation
          ? `Connect Bus Line ${lineNumber} to this existing interchange`
          : `Extend Bus Line ${lineNumber} to this stop`,
      stats: [
        {
          label: 'LINE',
          value:
            `${lineNumber} BUS`,
        },
        {
          label: 'STATION',
          value:
            existingStation
              ? 'EXISTING HUB'
              : 'NEW',
        },
        {
          label: 'NEW DEMAND',
          value:
            `+${getStopDemandPpm(
              state,
              lineKey,
              index,
            ).toFixed(1)} pax/min`,
        },
        {
          label: 'AFTER BUILD',
          value:
            line.stopCount <= 1
              ? 'SERVICE STARTS'
              : 'LINE EXTENDS',
        },
      ],
      actions: [
        {
          command: 'build-stop',
          lineKey,
          title:
            existingStation
              ? 'Connect station'
              : 'Build stop',
          detail:
            existingStation
              ? 'Extends the route into an already developed interchange'
              : 'Extends the route and activates another district',
          costLabel:
            money(cost),
          disabled:
            state.money < cost,
        },
      ],
    };
  }

  #getFutureLineView(
    state,
    lineKey,
  ) {
    const definitions = {
      line2: {
        unlocked:
          canUnlockLine2(state),
        cost:
          ECONOMY.line2BuildCost,
        previous: 'Line 1',
      },
      line3: {
        unlocked:
          canUnlockLine3(state),
        cost:
          ECONOMY.line3BuildCost,
        previous: 'Line 2',
      },
      line4: {
        unlocked:
          canUnlockLine4(state),
        cost:
          ECONOMY.line4BuildCost,
        previous: 'Line 3',
      },
    };

    const definition =
      definitions[lineKey];

    if (!definition) {
      return null;
    }

    const lineNumber =
      lineKey.replace(
        'line',
        '',
      );

    return {
      kicker: 'NEW SERVICE',
      title:
        `Bus Line ${lineNumber}`,
      subtitle:
        `${STOP_NAMES[lineKey][0]} → ${STOP_NAMES[lineKey][1]}`,
      stats: [
        {
          label: 'MODE',
          value: 'BUS',
        },
        {
          label: 'STARTER FLEET',
          value: '1 bus',
        },
        {
          label: 'STARTER STOPS',
          value: '2',
        },
        {
          label: 'REQUIRES',
          value:
            `${definition.previous} stable + garage slot`,
        },
      ],
      actions: [
        {
          command: 'build-line',
          lineKey,
          title:
            `Open Bus Line ${lineNumber}`,
          detail:
            'Creates a new physical service and opens fresh city growth corridors',
          costLabel:
            money(
              definition.cost,
            ),
          disabled:
            state.money
              < definition.cost
            || !definition.unlocked,
        },
      ],
    };
  }

  #getLineView(state, lineKey) {
    const line = state[lineKey];

    const isLine1 =
      lineKey === 'line1';

    if (
      !line.built
      && !(isLine1 && line.stopCount === 1)
    ) {
      return null;
    }

    const lineNumber =
      isLine1 ? 1 : 2;

    const demand =
      getLineDemandPpm(
        state,
        lineKey,
      );

    const capacity =
      getLineCapacityPpm(
        state,
        lineKey,
      );

    const waiting =
      getLineWaitingPassengers(
        state,
        lineKey,
      );

    const onboard =
      getLineOnboardPassengers(
        state,
        lineKey,
      );

    const mode =
      TRANSPORT_MODES[line.mode];

    const actions = [];

    if (line.built) {
      actions.push(
        this.#upgradeAction(
          state,
          isLine1
            ? 'shelter1'
            : 'shelter2',
          'Improve stops',
          '+30 waiting spaces at each stop',
        ),
      );
    }

    const catchmentUnlocked =
      isLine1
        ? line.stopCount >= 4
        : line.stopCount >= 3;

    if (catchmentUnlocked) {
      actions.push(
        this.#upgradeAction(
          state,
          isLine1
            ? 'catchment1'
            : 'catchment2',
          'Expand catchment',
          '+0.5 pax/min generated at every stop',
        ),
      );
    }

    return {
      kicker: 'SERVICE',
      title: `Bus Line ${lineNumber}`,
      subtitle:
        `${line.stopCount} stop${line.stopCount === 1 ? '' : 's'} · fares on arrival`,
      stats: [
        {
          label: 'FLEET',
          value:
            `${line.fleetCount} bus${line.fleetCount === 1 ? '' : 'es'}`,
        },
        {
          label: 'ON BOARD',
          value:
            `${onboard.toFixed(onboard < 10 ? 1 : 0)} pax`,
        },
        {
          label: 'WAITING',
          value:
            `${waiting.toFixed(waiting < 10 ? 1 : 0)} pax`,
          className:
            waiting > 8
              ? 'metric-warning'
              : '',
        },
        {
          label: 'HEADWAY',
          value: formatMinutes(
            getLineHeadwayMinutes(
              state,
              lineKey,
            ),
          ),
        },
        {
          label: 'ONE-WAY',
          value: formatMinutes(
            getLineOneWayMinutes(
              state,
              lineKey,
            ),
          ),
        },
        {
          label: 'THEORETICAL CAP.',
          value:
            `${capacity.toFixed(1)} pax/min`,
        },
        {
          label: 'DEMAND',
          value:
            `${demand.toFixed(1)} pax/min`,
          className:
            demand > capacity
              ? 'metric-warning'
              : '',
        },
        {
          label: 'RECENT ARRIVALS',
          value:
            `${line.lastDeliveredPpm.toFixed(1)} pax/min`,
        },
        {
          label: 'AVG WAIT',
          value:
            `${getAverageWaitMinutes(state).toFixed(1)} min`,
        },
      ],
      actions,
    };
  }

  #getDepotView(state) {
    const used =
      getGarageUsed(state);

    const vehicleCost =
      getVehiclePurchaseCost(state);

    const garageFull =
      used >= state.depot.garageSlots;

    const line1Full =
      state.line1.fleetCount
      >= ECONOMY.maxVehiclesPerLine;

    const line2Full =
      state.line2.fleetCount
      >= ECONOMY.maxVehiclesPerLine;

    const actions = [
      {
        command: 'add-vehicle-1',
        title: 'Buy bus for Line 1',
        detail:
          'Adds a real bus to the route and increases departures',
        costLabel:
          line1Full
            ? 'MAX'
            : garageFull
              ? 'GARAGE FULL'
              : money(vehicleCost),
        disabled:
          line1Full
          || garageFull
          || state.money < vehicleCost,
      },
    ];

    if (state.line2.built) {
      actions.push({
        command: 'add-vehicle-2',
        title: 'Buy bus for Line 2',
        detail:
          'Adds a real bus to Line 2',
        costLabel:
          line2Full
            ? 'MAX'
            : garageFull
              ? 'GARAGE FULL'
              : money(vehicleCost),
        disabled:
          line2Full
          || garageFull
          || state.money < vehicleCost,
      });
    }

    actions.push(
      this.#upgradeAction(
        state,
        'depot',
        'Expand garage',
        '+2 bus storage slots',
      ),
    );

    return {
      kicker: 'FACILITY',
      title: 'Bus Depot',
      subtitle:
        'Vehicles bought here appear directly on their assigned line',
      stats: [
        {
          label: 'GARAGE',
          value:
            `${used} / ${state.depot.garageSlots}`,
          className:
            garageFull
              ? 'metric-warning'
              : '',
        },
        {
          label: 'LINE 1',
          value:
            `${state.line1.fleetCount} buses`,
        },
        {
          label: 'LINE 2',
          value:
            state.line2.built
              ? `${state.line2.fleetCount} buses`
              : 'LOCKED',
        },
        {
          label: 'NEXT BUS',
          value:
            money(vehicleCost),
        },
      ],
      actions,
    };
  }

  #upgradeAction(
    state,
    type,
    title,
    detail,
  ) {
    const cost =
      getUpgradeCost(state, type);

    return {
      command: 'upgrade',
      type,
      title,
      detail,
      costLabel: money(cost),
      disabled:
        state.money < cost,
    };
  }

  #getProgressText(state) {
    if (!state.line1.built) {
      return '1 / 5 STOPS';
    }

    if (!state.depot.built) {
      return `${state.line1.stopCount} / 5 STOPS · DEPOT LOCKED`;
    }

    if (!state.line2.built) {
      if (
        state.line1.stopCount
          >= ECONOMY.maxLine1Stops
        && getBottleneck(state) === 'none'
        && getGarageUsed(state)
          >= state.depot.garageSlots
      ) {
        return 'EXPAND DEPOT FOR LINE 2';
      }

      return canUnlockLine2(state)
        ? 'LINE 2 UNLOCKED'
        : `${state.line1.stopCount} / 5 STOPS · BUILD LINE 1`;
    }

    return `2 LINES · ${getGarageUsed(state)} BUSES`;
  }

  #renderObjective(state) {
    const bottleneck =
      getBottleneck(state);

    if (!state.line1.built) {
      this.el.objective.textContent =
        'Buy Market Square. Passengers will wait, board the bus and pay only after arriving.';
      return;
    }

    if (
      state.line1.stopCount < 3
    ) {
      this.el.objective.textContent =
        'Watch passengers board, ride and pay when they exit. Use that fare money to extend Line 1.';
      return;
    }

    if (canBuildDepot(state)) {
      this.el.objective.textContent =
        'Bus Depot unlocked. Click its ghost building beside City Park.';
      return;
    }

    if (
      bottleneck === 'line-1'
      && state.depot.built
    ) {
      this.el.objective.textContent =
        'Passengers are waiting. Open the depot and add another physical bus.';
      return;
    }

    if (
      state.line1.stopCount
      < ECONOMY.maxLine1Stops
    ) {
      this.el.objective.textContent =
        'Extend Line 1 by buying the next visible stop.';
      return;
    }

    if (
      state.depot.built
      && getGarageUsed(state)
        >= state.depot.garageSlots
      && !state.line2.built
    ) {
      this.el.objective.textContent =
        'Line 1 is ready. Expand the depot to make room for the Line 2 starter bus.';
      return;
    }

    if (canUnlockLine2(state)) {
      this.el.objective.textContent =
        'Line 2 unlocked. Click the yellow branch at City Park.';
      return;
    }

    if (
      !state.line2.built
    ) {
      this.el.objective.textContent =
        'Stabilize Line 1 with enough buses to unlock a second service.';
      return;
    }

    if (bottleneck === 'line-2') {
      this.el.objective.textContent =
        'Line 2 passengers are waiting. Add another bus from the depot.';
      return;
    }

    if (
      state.line2.stopCount
      < ECONOMY.maxLine2Stops
    ) {
      this.el.objective.textContent =
        'Grow Line 2 by purchasing the next yellow stop.';
      return;
    }

    this.el.objective.textContent =
      'Bus network established. Every dollar now comes from completed passenger trips.';
  }

  toast(message) {
    this.el.toast.textContent = message;
    this.el.toast.classList.add('show');

    clearTimeout(this.toastTimer);

    this.toastTimer = setTimeout(
      () => this.el.toast.classList.remove('show'),
      1500,
    );
  }
}
