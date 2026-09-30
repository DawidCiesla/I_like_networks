import {
  ECONOMY,
  PLACES,
  TRANSPORT_MODES,
  getAbandonmentPercent,
  getAddStopACost,
  getAddStopBCost,
  getAverageWaitMinutes,
  getBottleneck,
  getCorridorADemandPpm,
  getCorridorBDemandPpm,
  getDeliveredPassengersPpm,
  getIncomePerSecond,
  getInterchangeIngressPpm,
  getLineCapacityPpm,
  getLineFrequencyPerHour,
  getLineHeadwayMinutes,
  getLineOneWayMinutes,
  getServiceBoard,
  getUpgradeCost,
  getVehiclePurchaseCost,
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

const BUILD_META = {
  lineA: {
    icon: '▰',
    title: 'Start Bus Line 1',
    detail: 'Includes 2 buses · Northside → Central Station',
  },
  terminalA: {
    icon: '▤',
    title: 'Build Northside Terminal',
    detail: 'Unlock more stops and waiting capacity',
  },
  interchange: {
    icon: '◆',
    title: 'Build Central Interchange',
    detail: 'Connect multiple corridors and destinations',
  },
  corridorB: {
    icon: '▰',
    title: 'Open Bus Line 2',
    detail: 'Includes 2 buses · Riverside → Central Interchange',
  },
  stationB: {
    icon: '▥',
    title: 'Build Harbor Station',
    detail: 'Extend Line 2 to a second destination',
  },
};

const formatMinutes = (value) =>
  `${value.toFixed(value < 10 ? 1 : 0)} min`;

export class Hud {
  constructor({
    onBuild,
    onAddStopA,
    onAddStopB,
    onAddVehicleA,
    onAddVehicleB,
    onUpgrade,
    onSpeed,
    onReset,
    onInspectorClose,
  }) {
    this.handlers = {
      onBuild,
      onAddStopA,
      onAddStopB,
      onAddVehicleA,
      onAddVehicleB,
      onUpgrade,
    };

    this.selection = null;
    this.buildOpen = false;
    this.lastState = null;

    this.buildStructureKey = null;
    this.inspectorStructureKey = null;
    this.serviceStructureKey = null;

    this.el = {
      money: document.querySelector('#money-value'),
      throughput: document.querySelector('#throughput-value'),
      income: document.querySelector('#income-value'),
      objective: document.querySelector('#objective-text'),

      buildButton: document.querySelector('#build-menu-button'),
      buildPanel: document.querySelector('#build-panel'),
      buildClose: document.querySelector('#build-panel-close'),
      buildList: document.querySelector('#build-list'),
      buildEmpty: document.querySelector('#build-empty'),

      inspector: document.querySelector('#inspector-panel'),
      inspectorClose: document.querySelector('#inspector-close'),
      inspectorKicker: document.querySelector('#inspector-kicker'),
      inspectorTitle: document.querySelector('#inspector-title'),
      inspectorSubtitle: document.querySelector('#inspector-subtitle'),
      inspectorStats: document.querySelector('#inspector-stats'),
      inspectorActions: document.querySelector('#inspector-actions'),

      inspectorServices: document.querySelector('#inspector-services'),
      serviceBoardBody: document.querySelector('#service-board-body'),
      serviceAThroughput: document.querySelector('#service-a-throughput'),
      serviceBThroughput: document.querySelector('#service-b-throughput'),

      toast: document.querySelector('#toast'),
      reset: document.querySelector('#reset-button'),
    };

    this.el.buildButton.addEventListener('click', () => {
      this.buildOpen = !this.buildOpen;
      this.#syncPanels();
    });

    this.el.buildClose.addEventListener('click', () => {
      this.buildOpen = false;
      this.#syncPanels();
    });

    this.el.inspectorClose.addEventListener('click', () => {
      this.selection = null;
      this.inspectorStructureKey = null;
      this.serviceStructureKey = null;
      onInspectorClose?.();
      this.#syncPanels();
    });

    this.el.buildList.addEventListener('click', (event) => {
      const button = event.target.closest('[data-build]');
      if (!button || button.disabled) return;

      this.handlers.onBuild(button.dataset.build);
    });

    this.el.inspectorActions.addEventListener('click', (event) => {
      const button = event.target.closest('[data-command]');
      if (!button || button.disabled) return;

      if (button.dataset.command === 'upgrade') {
        this.handlers.onUpgrade(button.dataset.type);
      } else if (button.dataset.command === 'add-stop-a') {
        this.handlers.onAddStopA();
      } else if (button.dataset.command === 'add-stop-b') {
        this.handlers.onAddStopB();
      } else if (button.dataset.command === 'add-vehicle-a') {
        this.handlers.onAddVehicleA();
      } else if (button.dataset.command === 'add-vehicle-b') {
        this.handlers.onAddVehicleB();
      }
    });

    const pauseButton = document.querySelector(
      '.speed-box > [data-speed="0"]',
    );

    pauseButton?.addEventListener(
      'click',
      () => onSpeed(this.currentSpeed === 0 ? 1 : 0),
    );

    document.querySelectorAll(
      '.speed-popover [data-speed]',
    ).forEach((button) => {
      button.addEventListener(
        'click',
        () => onSpeed(Number(button.dataset.speed)),
      );
    });

    this.el.reset.addEventListener('click', onReset);
  }

  setSelection(selection) {
    if (this.selection !== selection) {
      this.inspectorStructureKey = null;
      this.serviceStructureKey = null;
    }

    this.selection = selection;

    if (selection) {
      this.buildOpen = false;
    }

    this.#syncPanels();
  }

  render(state) {
    this.lastState = state;
    this.currentSpeed = state.simulationSpeed;

    const delivered = getDeliveredPassengersPpm(state);
    const income = getIncomePerSecond(state);

    this.el.money.textContent = compact(state.money);
    this.el.throughput.textContent =
      `${delivered.toFixed(1)} pax/min`;
    this.el.income.textContent =
      `+${compact(income)}/s`;

    this.#renderBuildMenu(state);
    this.#renderInspector(state);
    this.#renderObjective(state);
    this.#syncPanels();

    document.querySelectorAll('[data-speed]').forEach((button) => {
      button.classList.toggle(
        'active',
        Number(button.dataset.speed)
          === state.simulationSpeed,
      );
    });

    const pauseButton = document.querySelector(
      '.speed-box > [data-speed="0"]',
    );

    if (pauseButton) {
      pauseButton.textContent =
        state.simulationSpeed === 0
          ? '▶'
          : 'Ⅱ';
    }
  }

  #syncPanels() {
    this.el.buildPanel.classList.toggle(
      'hidden',
      !this.buildOpen,
    );

    this.el.buildButton.classList.toggle(
      'active',
      this.buildOpen,
    );

    this.el.inspector.classList.toggle(
      'hidden',
      !this.selection,
    );
  }

  #getBuildOptions(state) {
    if (!state.corridorA.lineBuilt) {
      return [{
        key: 'lineA',
        cost: ECONOMY.firstLineBuildCost,
      }];
    }

    if (!state.terminalA.built) {
      return [{
        key: 'terminalA',
        cost: ECONOMY.terminalBuildCost,
      }];
    }

    if (!state.interchange.built) {
      return [{
        key: 'interchange',
        cost: ECONOMY.interchangeBuildCost,
      }];
    }

    const options = [];

    if (!state.corridorB.built) {
      options.push({
        key: 'corridorB',
        cost: ECONOMY.corridorBBuildCost,
      });
    }

    if (!state.stationB.built) {
      options.push({
        key: 'stationB',
        cost: ECONOMY.stationBBuildCost,
      });
    }

    return options;
  }

  #renderBuildMenu(state) {
    const options = this.#getBuildOptions(state);

    const structureKey = options
      .map((option) => option.key)
      .join('|');

    if (structureKey !== this.buildStructureKey) {
      this.buildStructureKey = structureKey;
      this.el.buildList.replaceChildren();

      for (const option of options) {
        const meta = BUILD_META[option.key];
        const button = document.createElement('button');

        button.type = 'button';
        button.className = 'build-option';
        button.dataset.build = option.key;

        button.innerHTML = `
          <span class="build-option-icon">${meta.icon}</span>
          <span class="build-option-copy">
            <strong>${meta.title}</strong>
            <small>${meta.detail}</small>
          </span>
          <span class="build-option-cost"></span>
        `;

        this.el.buildList.append(button);
      }
    }

    for (const option of options) {
      const button = this.el.buildList.querySelector(
        `[data-build="${option.key}"]`,
      );

      if (!button) continue;

      button.disabled =
        state.money < option.cost;

      const cost =
        button.querySelector('.build-option-cost');

      if (cost) {
        cost.textContent = money(option.cost);
      }
    }

    this.el.buildEmpty.classList.toggle(
      'hidden',
      options.length > 0,
    );

    const available = options.filter(
      (option) => state.money >= option.cost,
    ).length;

    const suffix =
      options.length > 0
        ? ` ${available}/${options.length}`
        : '';

    this.el.buildButton
      .querySelector('span:last-child')
      .textContent = `BUILD${suffix}`;
  }

  #renderInspector(state) {
    if (!this.selection) return;

    const view = this.#getInspectorView(
      state,
      this.selection,
    );

    if (!view) {
      this.selection = null;
      this.inspectorStructureKey = null;
      this.serviceStructureKey = null;
      this.#syncPanels();
      return;
    }

    const showServices =
      this.selection === 'interchange'
      && state.interchange.built;

    const structureKey = JSON.stringify({
      selection: this.selection,
      stats: view.stats.map((stat) => stat.label),
      actions: view.actions.map((action) => [
        action.command,
        action.type ?? '',
        action.title,
        action.detail,
      ]),
      showServices,
    });

    if (
      structureKey !== this.inspectorStructureKey
    ) {
      this.inspectorStructureKey = structureKey;
      this.#buildInspectorStructure(view);
    }

    this.el.inspectorKicker.textContent = view.kicker;
    this.el.inspectorTitle.textContent = view.title;
    this.el.inspectorSubtitle.textContent = view.subtitle;

    const statRows = [
      ...this.el.inspectorStats.children,
    ];

    view.stats.forEach((stat, index) => {
      const row = statRows[index];
      if (!row) return;

      const value = row.querySelector('strong');
      if (!value) return;

      value.textContent = stat.value;
      value.className = stat.className ?? '';
    });

    const actionButtons = [
      ...this.el.inspectorActions
        .querySelectorAll('[data-command]'),
    ];

    view.actions.forEach((action, index) => {
      const button = actionButtons[index];
      if (!button) return;

      button.disabled = Boolean(action.disabled);

      const price =
        button.querySelector('.buy-pill');

      if (price) {
        price.textContent = action.costLabel;
      }
    });

    this.el.inspectorServices.classList.toggle(
      'hidden',
      !showServices,
    );

    if (showServices) {
      this.#renderServiceBoard(state);
    }
  }

  #buildInspectorStructure(view) {
    this.el.inspectorStats.replaceChildren();

    for (const stat of view.stats) {
      const row = document.createElement('div');
      row.className = 'inspector-stat';

      const label = document.createElement('span');
      label.textContent = stat.label;

      const value = document.createElement('strong');

      row.append(label, value);
      this.el.inspectorStats.append(row);
    }

    this.el.inspectorActions.replaceChildren();

    for (const action of view.actions) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'inspector-action';
      button.dataset.command = action.command;

      if (action.type) {
        button.dataset.type = action.type;
      }

      const copy = document.createElement('span');
      copy.className = 'inspector-action-copy';

      const title = document.createElement('strong');
      title.textContent = action.title;

      const detail = document.createElement('small');
      detail.textContent = action.detail;

      copy.append(title, detail);

      const price = document.createElement('span');
      price.className = 'buy-pill';

      button.append(copy, price);
      this.el.inspectorActions.append(button);
    }
  }

  #getLineView(state, corridorKey) {
    const isA = corridorKey === 'corridorA';
    const corridor = state[corridorKey];
    const mode = TRANSPORT_MODES[corridor.mode];

    const demand = isA
      ? getCorridorADemandPpm(state)
      : getCorridorBDemandPpm(state);

    const addStopCost = isA
      ? getAddStopACost(state)
      : getAddStopBCost(state);

    const maxStops = isA
      ? ECONOMY.maxStopsA
      : ECONOMY.maxStopsB;

    const vehicleCost = getVehiclePurchaseCost(
      state,
      corridorKey,
    );

    const fleetFull =
      corridor.fleetCount
      >= ECONOMY.maxVehiclesPerLine;

    const stopFull =
      corridor.stopCount >= maxStops;

    return {
      kicker: 'LINE',
      title: isA ? 'Bus Line 1' : 'Bus Line 2',
      subtitle: isA
        ? `${PLACES.corridorA.label} → ${PLACES.stationA.label}`
        : `${PLACES.corridorB.label} → ${state.stationB.built ? PLACES.stationB.label : 'Central Interchange'}`,
      stats: [
        {
          label: 'MODE',
          value: mode.label.toUpperCase(),
        },
        {
          label: 'FLEET',
          value: `${corridor.fleetCount} buses`,
        },
        {
          label: 'VEHICLE CAP.',
          value: `${mode.vehicleCapacity} pax`,
        },
        {
          label: 'HEADWAY',
          value: formatMinutes(
            getLineHeadwayMinutes(
              state,
              corridorKey,
            ),
          ),
        },
        {
          label: 'FREQUENCY',
          value: `${getLineFrequencyPerHour(state, corridorKey).toFixed(1)}/h`,
        },
        {
          label: 'ONE-WAY',
          value: formatMinutes(
            getLineOneWayMinutes(
              state,
              corridorKey,
            ),
          ),
        },
        {
          label: 'CAPACITY',
          value: `${getLineCapacityPpm(state, corridorKey).toFixed(1)} pax/min`,
        },
        {
          label: 'DEMAND',
          value: `${demand.toFixed(1)} pax/min`,
          className:
            demand
              > getLineCapacityPpm(
                state,
                corridorKey,
              )
              ? 'metric-warning'
              : '',
        },
      ],
      actions: [
        {
          command: isA
            ? 'add-vehicle-a'
            : 'add-vehicle-b',
          title: 'Buy another bus',
          detail:
            'Adds one vehicle and shortens service headway',
          costLabel: fleetFull
            ? 'MAX'
            : money(vehicleCost),
          disabled:
            fleetFull
            || state.money < vehicleCost,
        },
        {
          command: isA
            ? 'add-stop-a'
            : 'add-stop-b',
          title: 'Add stop',
          detail: isA
            ? 'Extends Line 1 and increases passenger demand'
            : 'Extends Line 2 and increases passenger demand',
          costLabel: stopFull
            ? 'MAX'
            : money(addStopCost),
          disabled:
            stopFull
            || (isA && !state.terminalA.built)
            || state.money < addStopCost,
        },
        ...(isA
          ? [
            this.#upgradeAction(
              state,
              'catchmentA',
              'Expand catchment',
              '+1 pax/min demand per stop',
            ),
          ]
          : []),
      ],
    };
  }

  #getInspectorView(state, selection) {
    const bottleneck = getBottleneck(state);
    const abandonment =
      getAbandonmentPercent(state);
    const averageWait =
      getAverageWaitMinutes(state);

    if (selection === 'corridorA') {
      return this.#getLineView(
        state,
        'corridorA',
      );
    }

    if (
      selection === 'terminalA'
      && state.terminalA.built
    ) {
      return {
        kicker: 'TERMINAL',
        title: 'Northside Terminal',
        subtitle: 'Local passenger collection point',
        stats: [
          {
            label: 'PLATFORM',
            value: `${state.terminalA.platformCapacityPpm} pax/min`,
          },
          {
            label: 'WAITING',
            value: `${state.terminalA.queuePassengers.toFixed(0)} pax`,
          },
          {
            label: 'WAITING AREA',
            value: `${state.terminalA.waitingCapacityPassengers} pax`,
          },
          {
            label: 'STATUS',
            value:
              bottleneck === 'terminal-a'
                ? 'BOTTLENECK'
                : 'OPEN',
            className:
              bottleneck === 'terminal-a'
                ? 'metric-warning'
                : '',
          },
        ],
        actions: [
          this.#upgradeAction(
            state,
            'terminalA',
            'Platform throughput',
            '+5 pax/min terminal capacity',
          ),
          ...(!state.interchange.built
            ? [
              this.#upgradeAction(
                state,
                'waitingArea',
                'Expand waiting area',
                '+40 passenger waiting capacity',
              ),
            ]
            : []),
        ],
      };
    }

    if (
      selection === 'interchange'
      && state.interchange.built
    ) {
      const totalWaiting =
        state.interchange.queuePassengers
        + state.interchange
          .destinationQueuesPassengers.primary
        + state.interchange
          .destinationQueuesPassengers.secondary;

      return {
        kicker: 'HUB',
        title: 'Central Interchange',
        subtitle: 'Transfers passengers between services',
        stats: [
          {
            label: 'TRANSFER CAP.',
            value: `${state.interchange.transferCapacityPpm} pax/min`,
          },
          {
            label: 'INGRESS',
            value: `${getInterchangeIngressPpm(state).toFixed(1)} pax/min`,
          },
          {
            label: 'WAITING',
            value: `${totalWaiting.toFixed(0)} pax`,
          },
          {
            label: 'AVG WAIT',
            value: `${averageWait.toFixed(1)} min`,
            className:
              averageWait > 5
                ? 'metric-warning'
                : '',
          },
          {
            label: 'LEFT QUEUE',
            value: `${abandonment.toFixed(abandonment < 1 ? 1 : 0)}%`,
            className:
              abandonment > 0
                ? 'metric-danger'
                : '',
          },
          {
            label: 'BOTTLENECK',
            value:
              bottleneck === 'none'
                ? 'NONE'
                : bottleneck.toUpperCase(),
            className:
              bottleneck === 'interchange'
                ? 'metric-warning'
                : '',
          },
        ],
        actions: [
          this.#upgradeAction(
            state,
            'interchange',
            'Expand interchange',
            '+10 pax/min transfer capacity',
          ),
        ],
      };
    }

    if (selection === 'stationA') {
      const stationIsBottleneck =
        bottleneck === 'station-a';

      return {
        kicker: 'DESTINATION',
        title: PLACES.stationA.label,
        subtitle: 'Primary passenger destination',
        stats: [
          {
            label: 'CAPACITY',
            value: `${state.stationA.capacityPpm} pax/min`,
          },
          {
            label: 'ARRIVALS',
            value: state.interchange.built
              ? `${state.interchange.lastDeliveredPpm.primary.toFixed(1)} pax/min`
              : `${getDeliveredPassengersPpm(state).toFixed(1)} pax/min`,
          },
          {
            label: 'WAITING TO ARRIVE',
            value: state.interchange.built
              ? `${state.interchange.destinationQueuesPassengers.primary.toFixed(0)} pax`
              : '—',
          },
          {
            label: 'STATUS',
            value:
              stationIsBottleneck
                ? 'BOTTLENECK'
                : 'OPEN',
            className:
              stationIsBottleneck
                ? 'metric-warning'
                : '',
          },
        ],
        actions: [
          this.#upgradeAction(
            state,
            'stationA',
            'Expand platforms',
            '+5 pax/min station capacity',
          ),
        ],
      };
    }

    if (
      selection === 'corridorB'
      && state.corridorB.built
    ) {
      return this.#getLineView(
        state,
        'corridorB',
      );
    }

    if (
      selection === 'stationB'
      && state.stationB.built
    ) {
      const stationIsBottleneck =
        bottleneck === 'station-b';

      return {
        kicker: 'DESTINATION',
        title: PLACES.stationB.label,
        subtitle: 'Second passenger destination',
        stats: [
          {
            label: 'CAPACITY',
            value: `${state.stationB.capacityPpm} pax/min`,
          },
          {
            label: 'ARRIVALS',
            value: `${state.interchange.lastDeliveredPpm.secondary.toFixed(1)} pax/min`,
          },
          {
            label: 'WAITING TO ARRIVE',
            value: `${state.interchange.destinationQueuesPassengers.secondary.toFixed(0)} pax`,
          },
          {
            label: 'STATUS',
            value:
              stationIsBottleneck
                ? 'BOTTLENECK'
                : 'OPEN',
            className:
              stationIsBottleneck
                ? 'metric-warning'
                : '',
          },
        ],
        actions: [
          this.#upgradeAction(
            state,
            'stationB',
            'Expand platforms',
            '+5 pax/min station capacity',
          ),
        ],
      };
    }

    return null;
  }

  #upgradeAction(
    state,
    type,
    title,
    detail,
  ) {
    const cost = getUpgradeCost(
      state,
      type,
    );

    return {
      command: 'upgrade',
      type,
      title,
      detail,
      costLabel: money(cost),
      disabled: state.money < cost,
    };
  }

  #renderServiceBoard(state) {
    const services = getServiceBoard(state);

    const structureKey = services
      .map((service) =>
        `${service.destination}:${service.service}:${service.mode}`,
      )
      .join('|');

    if (
      structureKey !== this.serviceStructureKey
    ) {
      this.serviceStructureKey = structureKey;
      this.el.serviceBoardBody.replaceChildren();

      for (const service of services) {
        const row = document.createElement('div');
        row.className = 'route-row service-row';

        const destination =
          document.createElement('span');

        destination.textContent =
          service.destination;

        const line =
          document.createElement('span');

        line.textContent =
          `${service.service} ${service.mode.toUpperCase()}`;

        const headway =
          document.createElement('span');

        headway.textContent =
          `${service.headwayMinutes.toFixed(1)}m`;

        row.append(
          destination,
          line,
          headway,
        );

        this.el.serviceBoardBody.append(row);
      }
    }

    this.el.serviceAThroughput.textContent =
      `${state.interchange.lastDeliveredPpm.primary.toFixed(1)} pax/min`;

    this.el.serviceBThroughput.textContent =
      state.stationB.built
        ? `${state.interchange.lastDeliveredPpm.secondary.toFixed(1)} pax/min`
        : '—';
  }

  #renderObjective(state) {
    const bottleneck = getBottleneck(state);

    if (!state.corridorA.lineBuilt) {
      this.el.objective.textContent =
        'Open BUILD and start Bus Line 1.';
      return;
    }

    if (
      bottleneck === 'line-a'
      && state.terminalA.built
    ) {
      this.el.objective.textContent =
        'Line 1 is overcrowded. Click it and add a bus.';
      return;
    }

    if (!state.terminalA.built) {
      this.el.objective.textContent =
        'Build Northside Terminal to add more stops.';
      return;
    }

    if (!state.interchange.built) {
      this.el.objective.textContent =
        'Build Central Interchange. Existing Line 1 stays in place.';
      return;
    }

    if (
      bottleneck === 'line-b'
      && state.corridorB.built
    ) {
      this.el.objective.textContent =
        'Line 2 is overcrowded. Add another bus to shorten headway.';
      return;
    }

    if (
      !state.corridorB.built
      || !state.stationB.built
    ) {
      this.el.objective.textContent =
        'Expand the city with another line or destination.';
      return;
    }

    if (bottleneck !== 'none') {
      this.el.objective.textContent =
        `Passenger bottleneck: ${bottleneck}. Click that element to improve it.`;
      return;
    }

    if (this.selection) {
      this.el.objective.textContent =
        'Fleet size now determines frequency and line capacity.';
      return;
    }

    this.el.objective.textContent =
      'Services stable. Add stops carefully: longer routes need more vehicles.';
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
