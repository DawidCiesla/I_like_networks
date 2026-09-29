import {
  ECONOMY,
  getAddBranchClientCost,
  getAddClientCost,
  getBottleneck,
  getBranchDemandMbps,
  getIncomePerSecond,
  getLatencyMs,
  getPacketLossPercent,
  getPrimaryDemandMbps,
  getRouteTable,
  getRouterIngressMbps,
  getThroughputMbps,
  getUpgradeCost,
} from '../simulation/model.js';

const compact = (value) => {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 0 : 1)}m`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(value >= 10_000 ? 0 : 1)}k`;
  return value.toFixed(value < 100 ? 1 : 0);
};

const money = (value) => `$${compact(value)}`;

const ACTION_META = {
  ethernet: { icon: '⇄', title: 'Ethernet Link', detail: 'Connect the first client to Server A' },
  switch: { icon: '▤', title: 'Install Switch', detail: 'Expand LAN A without replacing existing links' },
  router: { icon: '◆', title: 'Install Router', detail: 'Insert routing into the existing trunk' },
  branch: { icon: '▦', title: 'Build LAN B', detail: 'Add a second source network' },
  server2: { icon: '▥', title: 'Build Server B', detail: 'Add a second destination network' },
};

export class Hud {
  constructor({
    onBuild,
    onAddClient,
    onAddBranchClient,
    onUpgrade,
    onSpeed,
    onReset,
  }) {
    this.handlers = {
      onBuild,
      onAddClient,
      onAddBranchClient,
      onUpgrade,
    };

    this.selection = null;
    this.buildOpen = false;
    this.lastState = null;

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
      inspectorRoutes: document.querySelector('#inspector-routes'),
      routeTableBody: document.querySelector('#route-table-body'),
      routeAThroughput: document.querySelector('#route-a-throughput'),
      routeBThroughput: document.querySelector('#route-b-throughput'),
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
      } else if (button.dataset.command === 'add-client') {
        this.handlers.onAddClient();
      } else if (button.dataset.command === 'add-branch-client') {
        this.handlers.onAddBranchClient();
      }
    });

    const pauseButton = document.querySelector('.speed-box > [data-speed="0"]');
    pauseButton?.addEventListener('click', () => onSpeed(this.currentSpeed === 0 ? 1 : 0));

    document.querySelectorAll('.speed-popover [data-speed]').forEach((button) => {
      button.addEventListener('click', () => onSpeed(Number(button.dataset.speed)));
    });

    this.el.reset.addEventListener('click', onReset);
  }

  setSelection(selection) {
    this.selection = selection;
    if (selection) this.buildOpen = false;
    this.#syncPanels();
  }

  render(state) {
    this.lastState = state;
    this.currentSpeed = state.simulationSpeed;

    const throughput = getThroughputMbps(state);
    const income = getIncomePerSecond(state);

    this.el.money.textContent = compact(state.money);
    this.el.throughput.textContent = `${throughput.toFixed(0)} Mb/s`;
    this.el.income.textContent = `+${compact(income)}/s`;

    this.#renderBuildMenu(state);
    this.#renderInspector(state);
    this.#renderObjective(state);
    this.#syncPanels();

    document.querySelectorAll('[data-speed]').forEach((button) => {
      button.classList.toggle('active', Number(button.dataset.speed) === state.simulationSpeed);
    });

    const pauseButton = document.querySelector('.speed-box > [data-speed="0"]');
    if (pauseButton) pauseButton.textContent = state.simulationSpeed === 0 ? '▶' : 'Ⅱ';
  }

  #syncPanels() {
    this.el.buildPanel.classList.toggle('hidden', !this.buildOpen);
    this.el.buildButton.classList.toggle('active', this.buildOpen);
    this.el.inspector.classList.toggle('hidden', !this.selection);
  }

  #getBuildOptions(state) {
    const options = [];

    if (!state.linkBuilt) {
      options.push({ key: 'ethernet', cost: ECONOMY.ethernetBuildCost });
      return options;
    }

    if (!state.switch.built) {
      options.push({ key: 'switch', cost: ECONOMY.switchBuildCost });
      return options;
    }

    if (!state.router.built) {
      options.push({ key: 'router', cost: ECONOMY.routerBuildCost });
      return options;
    }

    if (!state.branch.built) {
      options.push({ key: 'branch', cost: ECONOMY.branchNetworkCost });
    }

    if (!state.secondaryServer.built) {
      options.push({ key: 'server2', cost: ECONOMY.secondaryServerCost });
    }

    return options;
  }

  #renderBuildMenu(state) {
    const options = this.#getBuildOptions(state);
    this.el.buildList.replaceChildren();

    for (const option of options) {
      const meta = ACTION_META[option.key];
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'build-option';
      button.dataset.build = option.key;
      button.disabled = state.money < option.cost;

      button.innerHTML = `
        <span class="build-option-icon">${meta.icon}</span>
        <span class="build-option-copy">
          <strong>${meta.title}</strong>
          <small>${meta.detail}</small>
        </span>
        <span class="build-option-cost">${money(option.cost)}</span>
      `;

      this.el.buildList.append(button);
    }

    this.el.buildEmpty.classList.toggle('hidden', options.length > 0);

    const available = options.filter((option) => state.money >= option.cost).length;
    const suffix = options.length > 0 ? ` ${available}/${options.length}` : '';
    this.el.buildButton.querySelector('span:last-child').textContent = `BUILD${suffix}`;
  }

  #renderInspector(state) {
    if (!this.selection) return;

    const view = this.#getInspectorView(state, this.selection);
    if (!view) {
      this.selection = null;
      return;
    }

    this.el.inspectorKicker.textContent = view.kicker;
    this.el.inspectorTitle.textContent = view.title;
    this.el.inspectorSubtitle.textContent = view.subtitle;

    this.el.inspectorStats.replaceChildren();
    for (const stat of view.stats) {
      const row = document.createElement('div');
      row.className = 'inspector-stat';
      row.innerHTML = `<span>${stat.label}</span><strong class="${stat.className ?? ''}">${stat.value}</strong>`;
      this.el.inspectorStats.append(row);
    }

    this.el.inspectorActions.replaceChildren();
    for (const action of view.actions) {
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'inspector-action';
      button.dataset.command = action.command;
      if (action.type) button.dataset.type = action.type;
      button.disabled = Boolean(action.disabled);

      button.innerHTML = `
        <span class="inspector-action-copy">
          <strong>${action.title}</strong>
          <small>${action.detail}</small>
        </span>
        <span class="buy-pill">${action.costLabel}</span>
      `;

      this.el.inspectorActions.append(button);
    }

    const showRoutes = this.selection === 'router' && state.router.built;
    this.el.inspectorRoutes.classList.toggle('hidden', !showRoutes);
    if (showRoutes) this.#renderRouteTable(state);
  }

  #getInspectorView(state, selection) {
    const bottleneck = getBottleneck(state);
    const loss = getPacketLossPercent(state);

    if (selection === 'lanA') {
      const addCost = getAddClientCost(state);
      return {
        kicker: 'NETWORK',
        title: 'LAN A',
        subtitle: '10.0.1.0/24',
        stats: [
          { label: 'CLIENTS', value: `${state.client.count} / ${ECONOMY.maxClients}` },
          { label: 'DEMAND', value: `${getPrimaryDemandMbps(state).toFixed(0)} Mb/s` },
          { label: 'PER CLIENT', value: `${state.client.trafficMbps} Mb/s` },
          { label: 'UPLINK', value: `${state.link.capacityMbps} Mb/s` },
        ],
        actions: [
          {
            command: 'add-client',
            title: 'Add client',
            detail: 'Connect another endpoint to LAN A',
            costLabel: state.client.count >= ECONOMY.maxClients ? 'MAX' : money(addCost),
            disabled: !state.switch.built
              || state.client.count >= ECONOMY.maxClients
              || state.money < addCost,
          },
          this.#upgradeAction(state, 'client', 'Client NIC', '+5 Mb/s demand per client'),
          this.#upgradeAction(state, 'link', 'LAN A uplink', '+20 Mb/s capacity'),
        ],
      };
    }

    if (selection === 'switch') {
      return {
        kicker: 'DEVICE',
        title: 'LAN A Switch',
        subtitle: 'Local switching fabric',
        stats: [
          { label: 'FABRIC', value: `${state.switch.capacityMbps} Mb/s` },
          { label: 'BUFFER', value: `${state.switch.bufferMb} Mb` },
          { label: 'QUEUE', value: `${state.switch.queueMb.toFixed(0)} Mb` },
          { label: 'STATUS', value: state.router.built ? 'LOCAL' : bottleneck === 'switch' ? 'BOTTLENECK' : 'ONLINE', className: bottleneck === 'switch' ? 'metric-warning' : '' },
        ],
        actions: [
          this.#upgradeAction(state, 'switch', 'Switch fabric', '+25 Mb/s switching'),
          this.#upgradeAction(state, 'buffer', 'Switch buffer', '+40 Mb queue'),
        ],
      };
    }

    if (selection === 'router' && state.router.built) {
      const totalQueue = state.router.queueMb
        + state.router.routeQueuesMb.primary
        + state.router.routeQueuesMb.secondary;

      return {
        kicker: 'DEVICE',
        title: 'Core Router',
        subtitle: 'Routes traffic between subnets',
        stats: [
          { label: 'CORE', value: `${state.router.capacityMbps} Mb/s` },
          { label: 'INGRESS', value: `${getRouterIngressMbps(state).toFixed(0)} Mb/s` },
          { label: 'QUEUE', value: `${totalQueue.toFixed(0)} Mb` },
          { label: 'LATENCY', value: `${getLatencyMs(state).toFixed(0)} ms` },
          { label: 'LOSS', value: `${loss.toFixed(loss < 1 ? 1 : 0)}%`, className: loss > 0 ? 'metric-danger' : '' },
          { label: 'BOTTLENECK', value: bottleneck === 'none' ? 'NONE' : bottleneck.toUpperCase(), className: bottleneck === 'router' ? 'metric-warning' : '' },
        ],
        actions: [
          this.#upgradeAction(state, 'router', 'Router core', '+40 Mb/s routed capacity'),
        ],
      };
    }

    if (selection === 'serverA') {
      return {
        kicker: 'DESTINATION',
        title: 'Server A',
        subtitle: '10.0.10.0/24',
        stats: [
          { label: 'CAPACITY', value: `${state.server.capacityMbps} Mb/s` },
          { label: 'TRAFFIC', value: state.router.built ? `${state.router.lastThroughputMbps.primary.toFixed(0)} Mb/s` : `${getThroughputMbps(state).toFixed(0)} Mb/s` },
          { label: 'ROUTE QUEUE', value: state.router.built ? `${state.router.routeQueuesMb.primary.toFixed(0)} Mb` : '—' },
          { label: 'STATUS', value: bottleneck === 'server-a' || bottleneck === 'server' ? 'BOTTLENECK' : 'ONLINE', className: bottleneck === 'server-a' || bottleneck === 'server' ? 'metric-warning' : '' },
        ],
        actions: [
          this.#upgradeAction(state, 'server', 'Server A capacity', '+15 Mb/s service capacity'),
        ],
      };
    }

    if (selection === 'lanB' && state.branch.built) {
      const addCost = getAddBranchClientCost(state);
      return {
        kicker: 'NETWORK',
        title: 'LAN B',
        subtitle: '10.0.2.0/24',
        stats: [
          { label: 'CLIENTS', value: `${state.branch.clientCount} / ${ECONOMY.maxBranchClients}` },
          { label: 'DEMAND', value: `${getBranchDemandMbps(state).toFixed(0)} Mb/s` },
          { label: 'PER CLIENT', value: `${state.branch.clientTrafficMbps} Mb/s` },
          { label: 'UPLINK', value: `${state.branch.linkCapacityMbps} Mb/s` },
        ],
        actions: [
          {
            command: 'add-branch-client',
            title: 'Add client',
            detail: 'Connect another endpoint to LAN B',
            costLabel: state.branch.clientCount >= ECONOMY.maxBranchClients ? 'MAX' : money(addCost),
            disabled: state.branch.clientCount >= ECONOMY.maxBranchClients
              || state.money < addCost,
          },
          this.#upgradeAction(state, 'branch', 'LAN B uplink', '+20 Mb/s capacity'),
        ],
      };
    }

    if (selection === 'serverB' && state.secondaryServer.built) {
      return {
        kicker: 'DESTINATION',
        title: 'Server B',
        subtitle: '10.0.20.0/24',
        stats: [
          { label: 'CAPACITY', value: `${state.secondaryServer.capacityMbps} Mb/s` },
          { label: 'UPLINK', value: `${state.secondaryServer.linkCapacityMbps} Mb/s` },
          { label: 'TRAFFIC', value: `${state.router.lastThroughputMbps.secondary.toFixed(0)} Mb/s` },
          { label: 'ROUTE QUEUE', value: `${state.router.routeQueuesMb.secondary.toFixed(0)} Mb` },
          { label: 'STATUS', value: bottleneck === 'server-b' ? 'BOTTLENECK' : 'ONLINE', className: bottleneck === 'server-b' ? 'metric-warning' : '' },
        ],
        actions: [
          this.#upgradeAction(state, 'server2', 'Server B capacity', '+20 Mb/s service + uplink'),
        ],
      };
    }

    return null;
  }

  #upgradeAction(state, type, title, detail) {
    const cost = getUpgradeCost(state, type);
    return {
      command: 'upgrade',
      type,
      title,
      detail,
      costLabel: money(cost),
      disabled: state.money < cost,
    };
  }

  #renderRouteTable(state) {
    this.el.routeTableBody.replaceChildren();

    for (const route of getRouteTable(state)) {
      const row = document.createElement('div');
      row.className = 'route-row';

      const destination = document.createElement('span');
      destination.textContent = route.destination;

      const nextHop = document.createElement('span');
      nextHop.textContent = route.nextHop;

      row.append(destination, nextHop);
      this.el.routeTableBody.append(row);
    }

    this.el.routeAThroughput.textContent =
      `${state.router.lastThroughputMbps.primary.toFixed(0)} Mb/s`;
    this.el.routeBThroughput.textContent = state.secondaryServer.built
      ? `${state.router.lastThroughputMbps.secondary.toFixed(0)} Mb/s`
      : '—';
  }

  #renderObjective(state) {
    const bottleneck = getBottleneck(state);

    if (!state.linkBuilt) {
      this.el.objective.textContent = 'Open BUILD and connect the first Ethernet link.';
      return;
    }

    if (!state.switch.built) {
      this.el.objective.textContent = 'Add a switch. Existing links will stay where they are.';
      return;
    }

    if (!state.router.built) {
      this.el.objective.textContent = 'Insert a router into the existing trunk.';
      return;
    }

    if (!state.branch.built || !state.secondaryServer.built) {
      this.el.objective.textContent = 'Expand the existing map with another network or server.';
      return;
    }

    if (bottleneck !== 'none') {
      this.el.objective.textContent = `Bottleneck: ${bottleneck}. Click that element to upgrade it.`;
      return;
    }

    if (this.selection) {
      this.el.objective.textContent = 'Selected element shows only its own upgrades.';
      return;
    }

    this.el.objective.textContent = 'Network stable. Click any device or LAN to inspect it.';
  }

  toast(message) {
    this.el.toast.textContent = message;
    this.el.toast.classList.add('show');
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => this.el.toast.classList.remove('show'), 1500);
  }
}
