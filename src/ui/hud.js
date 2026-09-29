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

export class Hud {
  constructor({
    onConnect,
    onBuildSwitch,
    onBuildRouter,
    onAddClient,
    onBuildBranch,
    onAddBranchClient,
    onBuildSecondaryServer,
    onUpgrade,
    onSpeed,
    onReset,
  }) {
    this.el = {
      money: document.querySelector('#money-value'),
      throughput: document.querySelector('#throughput-value'),
      income: document.querySelector('#income-value'),
      objective: document.querySelector('#objective-text'),

      connect: document.querySelector('#connect-button'),
      connectSubtitle: document.querySelector('#connect-subtitle'),
      connectCost: document.querySelector('#connect-cost'),

      switchButton: document.querySelector('#switch-button'),
      switchSubtitle: document.querySelector('#switch-subtitle'),
      switchCost: document.querySelector('#switch-cost'),

      routerButton: document.querySelector('#router-button'),
      routerSubtitle: document.querySelector('#router-subtitle'),
      routerCost: document.querySelector('#router-cost'),

      addClientButton: document.querySelector('#add-client-button'),
      addClientCost: document.querySelector('#add-client-cost'),
      clientCount: document.querySelector('#client-count-text'),

      branchButton: document.querySelector('#branch-button'),
      branchSubtitle: document.querySelector('#branch-subtitle'),
      branchCost: document.querySelector('#branch-cost'),

      branchClientButton: document.querySelector('#branch-client-button'),
      branchClientCost: document.querySelector('#branch-client-cost'),
      branchClientCount: document.querySelector('#branch-client-count'),

      secondaryServerButton: document.querySelector('#secondary-server-button'),
      secondaryServerSubtitle: document.querySelector('#secondary-server-subtitle'),
      secondaryServerCost: document.querySelector('#secondary-server-cost'),

      demandA: document.querySelector('#demand-a-value'),
      demandB: document.querySelector('#demand-b-value'),
      routerIngress: document.querySelector('#router-ingress-value'),
      routerCapacity: document.querySelector('#router-capacity-value'),
      queue: document.querySelector('#queue-value'),
      latency: document.querySelector('#latency-value'),
      loss: document.querySelector('#loss-value'),
      bottleneck: document.querySelector('#bottleneck-value'),

      routeTableBox: document.querySelector('#route-table-box'),
      routeTableBody: document.querySelector('#route-table-body'),
      routeAThroughput: document.querySelector('#route-a-throughput'),
      routeBThroughput: document.querySelector('#route-b-throughput'),

      toast: document.querySelector('#toast'),
      reset: document.querySelector('#reset-button'),
    };

    this.el.connect.addEventListener('click', onConnect);
    this.el.switchButton.addEventListener('click', onBuildSwitch);
    this.el.routerButton.addEventListener('click', onBuildRouter);
    this.el.addClientButton.addEventListener('click', onAddClient);
    this.el.branchButton.addEventListener('click', onBuildBranch);
    this.el.branchClientButton.addEventListener('click', onAddBranchClient);
    this.el.secondaryServerButton.addEventListener('click', onBuildSecondaryServer);

    document.querySelectorAll('[data-upgrade]').forEach((button) => {
      button.addEventListener('click', () => onUpgrade(button.dataset.upgrade));
    });

    const pauseButton = document.querySelector('.speed-box > [data-speed="0"]');
    pauseButton?.addEventListener('click', () => onSpeed(this.currentSpeed === 0 ? 1 : 0));

    document.querySelectorAll('.speed-popover [data-speed]').forEach((button) => {
      button.addEventListener('click', () => onSpeed(Number(button.dataset.speed)));
    });

    this.el.reset.addEventListener('click', onReset);
  }

  render(state) {
    this.currentSpeed = state.simulationSpeed;

    const throughput = getThroughputMbps(state);
    const income = getIncomePerSecond(state);
    const primaryDemand = getPrimaryDemandMbps(state);
    const branchDemand = getBranchDemandMbps(state);
    const routerIngress = getRouterIngressMbps(state);
    const latency = getLatencyMs(state);
    const loss = getPacketLossPercent(state);
    const bottleneck = getBottleneck(state);

    this.el.money.textContent = compact(state.money);
    this.el.throughput.textContent = `${throughput.toFixed(0)} Mb/s`;
    this.el.income.textContent = `+${compact(income)}/s`;

    this.el.demandA.textContent = `${primaryDemand.toFixed(0)} Mb/s`;
    this.el.demandB.textContent = state.branch.built ? `${branchDemand.toFixed(0)} Mb/s` : '—';
    this.el.routerIngress.textContent = state.router.built ? `${routerIngress.toFixed(0)} Mb/s` : '—';
    this.el.routerCapacity.textContent = state.router.built ? `${state.router.capacityMbps} Mb/s` : '—';

    const totalQueue = state.router.built
      ? state.router.queueMb
        + state.router.routeQueuesMb.primary
        + state.router.routeQueuesMb.secondary
      : state.switch.queueMb;

    this.el.queue.textContent = `${totalQueue.toFixed(0)} Mb`;
    this.el.latency.textContent = state.linkBuilt ? `${latency.toFixed(0)} ms` : '—';
    this.el.loss.textContent = state.router.built ? `${loss.toFixed(loss < 1 ? 1 : 0)}%` : '—';
    this.el.bottleneck.textContent = bottleneck === 'none' ? 'NONE' : bottleneck.toUpperCase();

    this.el.queue.classList.toggle('metric-warning', totalQueue > 0 && totalQueue < state.router.bufferMb);
    this.el.queue.classList.toggle(
      'metric-danger',
      state.router.built && totalQueue >= state.router.bufferMb,
    );
    this.el.loss.classList.toggle('metric-danger', loss > 0);
    this.el.bottleneck.classList.toggle('metric-warning', !['none', 'offline'].includes(bottleneck));

    this.el.connect.disabled = state.linkBuilt || state.money < ECONOMY.ethernetBuildCost;
    this.el.connectSubtitle.textContent = state.linkBuilt ? 'Traffic online' : 'Client ↔ Server';
    this.el.connectCost.textContent = state.linkBuilt ? 'ONLINE' : money(ECONOMY.ethernetBuildCost);

    this.el.switchButton.disabled = !state.linkBuilt
      || state.switch.built
      || state.money < ECONOMY.switchBuildCost;
    this.el.switchSubtitle.textContent = state.switch.built
      ? `${state.switch.capacityMbps} Mb/s fabric`
      : 'Unlock multiple clients';
    this.el.switchCost.textContent = state.switch.built ? 'ONLINE' : money(ECONOMY.switchBuildCost);

    this.el.routerButton.disabled = !state.switch.built
      || state.router.built
      || state.money < ECONOMY.routerBuildCost;
    this.el.routerSubtitle.textContent = state.router.built
      ? `${state.router.capacityMbps} Mb/s routed core`
      : 'Route traffic between networks';
    this.el.routerCost.textContent = state.router.built ? 'ONLINE' : money(ECONOMY.routerBuildCost);

    const addClientCost = getAddClientCost(state);
    this.el.addClientButton.disabled = !state.switch.built
      || state.client.count >= ECONOMY.maxClients
      || state.money < addClientCost;
    this.el.clientCount.textContent = `${state.client.count} / ${ECONOMY.maxClients} connected`;
    this.el.addClientCost.textContent = state.client.count >= ECONOMY.maxClients
      ? 'MAX'
      : money(addClientCost);

    this.el.branchButton.disabled = !state.router.built
      || state.branch.built
      || state.money < ECONOMY.branchNetworkCost;
    this.el.branchSubtitle.textContent = state.branch.built
      ? `${state.branch.linkCapacityMbps} Mb/s uplink`
      : 'Second routed subnet';
    this.el.branchCost.textContent = state.branch.built
      ? 'ONLINE'
      : money(ECONOMY.branchNetworkCost);

    const branchClientCost = getAddBranchClientCost(state);
    this.el.branchClientButton.disabled = !state.branch.built
      || state.branch.clientCount >= ECONOMY.maxBranchClients
      || state.money < branchClientCost;
    this.el.branchClientCount.textContent =
      `${state.branch.clientCount} / ${ECONOMY.maxBranchClients} connected`;
    this.el.branchClientCost.textContent = state.branch.clientCount >= ECONOMY.maxBranchClients
      ? 'MAX'
      : money(branchClientCost);

    this.el.secondaryServerButton.disabled = !state.router.built
      || state.secondaryServer.built
      || state.money < ECONOMY.secondaryServerCost;
    this.el.secondaryServerSubtitle.textContent = state.secondaryServer.built
      ? `${state.secondaryServer.capacityMbps} Mb/s destination`
      : 'Add second destination network';
    this.el.secondaryServerCost.textContent = state.secondaryServer.built
      ? 'ONLINE'
      : money(ECONOMY.secondaryServerCost);

    document.querySelectorAll('[data-upgrade]').forEach((button) => {
      const type = button.dataset.upgrade;
      const cost = getUpgradeCost(state, type);
      const costElement = button.querySelector('.row-cost strong');
      if (costElement) costElement.textContent = money(cost);

      const missingDependency =
        (type === 'link' && !state.linkBuilt)
        || (type === 'router' && !state.router.built)
        || (type === 'branch' && !state.branch.built)
        || (type === 'server2' && !state.secondaryServer.built);

      button.disabled = missingDependency || state.money < cost;
    });

    this.#renderRouteTable(state);
    this.#renderObjective(state, loss, bottleneck);

    document.querySelectorAll('[data-speed]').forEach((button) => {
      button.classList.toggle('active', Number(button.dataset.speed) === state.simulationSpeed);
    });

    const pauseButton = document.querySelector('.speed-box > [data-speed="0"]');
    if (pauseButton) pauseButton.textContent = state.simulationSpeed === 0 ? '▶' : 'Ⅱ';
  }

  #renderRouteTable(state) {
    this.el.routeTableBox.classList.toggle('hidden', !state.router.built);
    if (!state.router.built) return;

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

  #renderObjective(state, loss, bottleneck) {
    if (!state.linkBuilt) {
      this.el.objective.textContent = 'Connect the first network.';
      return;
    }

    if (!state.switch.built) {
      this.el.objective.textContent = 'Install a switch to grow LAN A.';
      return;
    }

    if (!state.router.built) {
      this.el.objective.textContent = 'Install a router to connect multiple networks.';
      return;
    }

    if (!state.branch.built) {
      this.el.objective.textContent = 'Build LAN B and watch the router learn its subnet.';
      return;
    }

    if (!state.secondaryServer.built) {
      this.el.objective.textContent = 'Add Server B to create a second routed destination.';
      return;
    }

    if (loss > 0) {
      this.el.objective.textContent = `Routing overloaded — bottleneck: ${bottleneck}.`;
      return;
    }

    if (bottleneck !== 'none') {
      this.el.objective.textContent = `Bottleneck detected: ${bottleneck}.`;
      return;
    }

    this.el.objective.textContent = 'Multiple networks online. Routing stable.';
  }

  toast(message) {
    this.el.toast.textContent = message;
    this.el.toast.classList.add('show');
    clearTimeout(this.toastTimer);
    this.toastTimer = setTimeout(() => this.el.toast.classList.remove('show'), 1500);
  }
}
