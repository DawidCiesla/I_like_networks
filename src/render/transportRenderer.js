import {
  ECONOMY,
  STOP_NAMES,
  TRANSPORT_MODES,
  canBuildDepot,
  canUnlockLine2,
  getAverageWaitMinutes,
  getBottleneck,
  getDeliveredPassengersPpm,
  getIncomePerSecond,
  getLineDemandPpm,
  getNextStopCost,
} from '../simulation/model.js';

const clamp = (value, min, max) =>
  Math.min(max, Math.max(min, value));

const LINE_1_COLOR = '#0797ec';
const LINE_2_COLOR = '#f4ca00';

const WORLD = Object.freeze({
  line1Stops: [
    { x: -430, y: -80, w: 58, h: 64 },
    { x: -280, y: -80, w: 58, h: 64 },
    { x: -130, y: -110, w: 58, h: 64 },
    { x: 40, y: -70, w: 58, h: 64 },
    { x: 220, y: -105, w: 66, h: 70 },
  ],
  line2Stops: [
    { x: -130, y: -110, w: 58, h: 64 },
    { x: -35, y: 85, w: 58, h: 64 },
    { x: 125, y: 175, w: 58, h: 64 },
    { x: 310, y: 195, w: 66, h: 70 },
  ],
  depot: {
    x: -115,
    y: 55,
    w: 118,
    h: 86,
  },
});

function routeMetrics(points) {
  const segments = [];
  let total = 0;

  for (let index = 0; index < points.length - 1; index += 1) {
    const a = points[index];
    const b = points[index + 1];
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length = Math.hypot(dx, dy);

    segments.push({
      a,
      b,
      dx,
      dy,
      length,
      start: total,
    });

    total += length;
  }

  return {
    points,
    segments,
    total,
  };
}

function pointOnRoute(metrics, distance) {
  if (metrics.total <= 0) {
    return {
      x: metrics.points[0]?.x ?? 0,
      y: metrics.points[0]?.y ?? 0,
      tx: 1,
      ty: 0,
    };
  }

  const wrapped =
    ((distance % metrics.total) + metrics.total)
    % metrics.total;

  const segment =
    metrics.segments.find(
      (item) =>
        wrapped <= item.start + item.length,
    )
    ?? metrics.segments.at(-1);

  const local = clamp(
    (wrapped - segment.start)
      / Math.max(1, segment.length),
    0,
    1,
  );

  return {
    x: segment.a.x + segment.dx * local,
    y: segment.a.y + segment.dy * local,
    tx: segment.dx / Math.max(1, segment.length),
    ty: segment.dy / Math.max(1, segment.length),
  };
}

function builtRoute(stopRects, stopCount) {
  return routeMetrics(
    stopRects
      .slice(0, Math.max(1, stopCount))
      .map(({ x, y }) => ({ x, y })),
  );
}

export class TransportRenderer {
  constructor(canvas, { onSelectionChanged } = {}) {
    this.canvas = canvas;
    this.ctx = canvas.getContext('2d');
    this.ctx.imageSmoothingEnabled = false;

    this.dpr = Math.min(
      window.devicePixelRatio || 1,
      2,
    );

    this.camera = {
      x: 65,
      y: 20,
      zoom: 1,
    };

    this.pointer = {
      dragging: false,
      x: 0,
      y: 0,
      startX: 0,
      startY: 0,
    };

    this.time = 0;
    this.selected = null;
    this.hitTargets = [];
    this.onSelectionChanged =
      onSelectionChanged;

    this.#bindInput();
    this.resize();
  }

  setSelection(selection) {
    this.selected = selection;
  }

  resize() {
    const rect =
      this.canvas.getBoundingClientRect();

    this.canvas.width = Math.max(
      1,
      Math.floor(rect.width * this.dpr),
    );

    this.canvas.height = Math.max(
      1,
      Math.floor(rect.height * this.dpr),
    );

    this.ctx.imageSmoothingEnabled = false;
  }

  #bindInput() {
    this.canvas.addEventListener(
      'pointerdown',
      (event) => {
        this.pointer.dragging = true;
        this.pointer.x = event.clientX;
        this.pointer.y = event.clientY;
        this.pointer.startX = event.clientX;
        this.pointer.startY = event.clientY;
        this.canvas.setPointerCapture(
          event.pointerId,
        );
      },
    );

    this.canvas.addEventListener(
      'pointermove',
      (event) => {
        if (!this.pointer.dragging) return;

        this.camera.x +=
          (event.clientX - this.pointer.x)
          / this.camera.zoom;

        this.camera.y +=
          (event.clientY - this.pointer.y)
          / this.camera.zoom;

        this.pointer.x = event.clientX;
        this.pointer.y = event.clientY;
      },
    );

    this.canvas.addEventListener(
      'pointerup',
      (event) => {
        const moved = Math.hypot(
          event.clientX - this.pointer.startX,
          event.clientY - this.pointer.startY,
        );

        this.pointer.dragging = false;

        if (moved < 5) {
          this.#selectAt(
            event.clientX,
            event.clientY,
          );
        }
      },
    );

    this.canvas.addEventListener(
      'wheel',
      (event) => {
        event.preventDefault();

        this.camera.zoom = clamp(
          this.camera.zoom
            * (event.deltaY > 0 ? 0.9 : 1.1),
          0.55,
          2.2,
        );
      },
      { passive: false },
    );

    window.addEventListener(
      'resize',
      () => this.resize(),
    );
  }

  #screenToWorld(clientX, clientY) {
    const rect =
      this.canvas.getBoundingClientRect();

    return {
      x:
        (clientX - rect.left - rect.width / 2)
          / this.camera.zoom
        - this.camera.x,
      y:
        (clientY - rect.top - rect.height / 2)
          / this.camera.zoom
        - this.camera.y,
    };
  }

  #selectAt(clientX, clientY) {
    const point =
      this.#screenToWorld(clientX, clientY);

    const target = [...this.hitTargets]
      .reverse()
      .find(({ rect }) => (
        point.x >= rect.x - rect.w / 2
        && point.x <= rect.x + rect.w / 2
        && point.y >= rect.y - rect.h / 2
        && point.y <= rect.y + rect.h / 2
      ));

    this.selected = target?.id ?? null;

    this.onSelectionChanged?.(
      this.selected,
    );
  }

  render(state, deltaSeconds) {
    this.time += deltaSeconds;
    this.hitTargets = [];

    const ctx = this.ctx;

    const width =
      this.canvas.width / this.dpr;

    const height =
      this.canvas.height / this.dpr;

    ctx.setTransform(
      this.dpr,
      0,
      0,
      this.dpr,
      0,
      0,
    );

    ctx.imageSmoothingEnabled = false;
    ctx.clearRect(0, 0, width, height);

    this.#drawBackground(
      ctx,
      width,
      height,
    );

    ctx.save();

    ctx.translate(
      width / 2,
      height / 2,
    );

    ctx.scale(
      this.camera.zoom,
      this.camera.zoom,
    );

    ctx.translate(
      this.camera.x,
      this.camera.y,
    );

    this.#drawBusEra(ctx, state);

    ctx.restore();
  }

  #drawBackground(ctx, width, height) {
    ctx.fillStyle = '#1a1a1a';
    ctx.fillRect(0, 0, width, height);

    const spacing = 22;

    const offsetX =
      ((this.camera.x * this.camera.zoom)
        % spacing + spacing)
      % spacing;

    const offsetY =
      ((this.camera.y * this.camera.zoom)
        % spacing + spacing)
      % spacing;

    ctx.fillStyle = '#242424';

    for (
      let x = offsetX;
      x < width;
      x += spacing
    ) {
      for (
        let y = offsetY;
        y < height;
        y += spacing
      ) {
        const px = Math.round(x);
        const py = Math.round(y);

        ctx.fillRect(
          px - 2,
          py,
          5,
          1,
        );

        ctx.fillRect(
          px,
          py - 2,
          1,
          5,
        );
      }
    }
  }

  #drawBusEra(ctx, state) {
    this.#drawLine1(ctx, state);
    this.#drawDepot(ctx, state);
    this.#drawLine2(ctx, state);
    this.#drawSystemReadout(ctx, state);
  }

  #drawLine1(ctx, state) {
    const route = builtRoute(
      WORLD.line1Stops,
      state.line1.stopCount,
    );

    if (state.line1.built) {
      this.#drawTransitLine(
        ctx,
        route,
        LINE_1_COLOR,
        1,
      );

      this.#drawVehicles(
        ctx,
        route,
        state.line1.fleetCount,
        LINE_1_COLOR,
        state.line1.mode,
      );
    }

    for (
      let index = 0;
      index < state.line1.stopCount;
      index += 1
    ) {
      const rect =
        WORLD.line1Stops[index];

      this.#drawStop(
        ctx,
        rect,
        STOP_NAMES.line1[index],
        index + 1,
        LINE_1_COLOR,
        this.selected === 'line1',
        index === 0,
      );

      this.hitTargets.push({
        id: 'line1',
        rect,
      });
    }

    if (
      state.line1.stopCount
      < ECONOMY.maxLine1Stops
    ) {
      const current =
        WORLD.line1Stops[
          state.line1.stopCount - 1
        ];

      const next =
        WORLD.line1Stops[
          state.line1.stopCount
        ];

      const ghostRoute = routeMetrics([
        { x: current.x, y: current.y },
        { x: next.x, y: next.y },
      ]);

      this.#drawGhostLine(
        ctx,
        ghostRoute,
        LINE_1_COLOR,
      );

      this.#drawFutureStop(
        ctx,
        next,
        STOP_NAMES.line1[
          state.line1.stopCount
        ],
        getNextStopCost(
          state,
          'line1',
        ),
        LINE_1_COLOR,
        this.selected === 'futureStop1',
      );

      this.hitTargets.push({
        id: 'futureStop1',
        rect: {
          ...next,
          w: 86,
          h: 86,
        },
      });
    }

    if (
      state.line1.queuePassengers > 0
    ) {
      const first =
        WORLD.line1Stops[0];

      this.#drawPassengerQueue(
        ctx,
        first.x - 66,
        first.y + 54,
        state.line1.queuePassengers,
        state.line1.waitingCapacityPassengers,
      );
    }

    if (state.line1.built) {
      this.#drawRevenuePulse(
        ctx,
        state,
        WORLD.line1Stops[
          state.line1.stopCount - 1
        ],
      );
    }
  }

  #drawDepot(ctx, state) {
    const anchor =
      WORLD.line1Stops[2];

    if (state.depot.built) {
      const spur = routeMetrics([
        {
          x: anchor.x,
          y: anchor.y,
        },
        {
          x: WORLD.depot.x,
          y: WORLD.depot.y - 35,
        },
      ]);

      this.#drawServiceSpur(
        ctx,
        spur,
        '#b7b7ae',
      );

      this.#drawDepotBuilding(
        ctx,
        WORLD.depot,
        state,
        this.selected === 'depot',
      );

      this.hitTargets.push({
        id: 'depot',
        rect: WORLD.depot,
      });

      return;
    }

    if (!canBuildDepot(state)) {
      return;
    }

    const spur = routeMetrics([
      {
        x: anchor.x,
        y: anchor.y,
      },
      {
        x: WORLD.depot.x,
        y: WORLD.depot.y - 35,
      },
    ]);

    this.#drawGhostLine(
      ctx,
      spur,
      '#b7b7ae',
    );

    this.#drawFutureDepot(
      ctx,
      WORLD.depot,
      ECONOMY.depotBuildCost,
      this.selected === 'futureDepot',
    );

    this.hitTargets.push({
      id: 'futureDepot',
      rect: {
        ...WORLD.depot,
        w: 132,
        h: 100,
      },
    });
  }

  #drawLine2(ctx, state) {
    if (!state.line2.built) {
      if (!canUnlockLine2(state)) return;

      const route = routeMetrics([
        {
          x: WORLD.line2Stops[0].x,
          y: WORLD.line2Stops[0].y,
        },
        {
          x: WORLD.line2Stops[1].x,
          y: WORLD.line2Stops[1].y,
        },
      ]);

      this.#drawGhostLine(
        ctx,
        route,
        LINE_2_COLOR,
      );

      this.#drawFutureLine(
        ctx,
        WORLD.line2Stops[1],
        ECONOMY.line2BuildCost,
        this.selected === 'futureLine2',
      );

      this.hitTargets.push({
        id: 'futureLine2',
        rect: {
          ...WORLD.line2Stops[1],
          w: 104,
          h: 92,
        },
      });

      return;
    }

    const route = builtRoute(
      WORLD.line2Stops,
      state.line2.stopCount,
    );

    this.#drawTransitLine(
      ctx,
      route,
      LINE_2_COLOR,
      2,
    );

    this.#drawVehicles(
      ctx,
      route,
      state.line2.fleetCount,
      LINE_2_COLOR,
      state.line2.mode,
    );

    for (
      let index = 1;
      index < state.line2.stopCount;
      index += 1
    ) {
      const rect =
        WORLD.line2Stops[index];

      this.#drawStop(
        ctx,
        rect,
        STOP_NAMES.line2[index],
        index + 1,
        LINE_2_COLOR,
        this.selected === 'line2',
        false,
      );

      this.hitTargets.push({
        id: 'line2',
        rect,
      });
    }

    if (
      state.line2.stopCount
      < ECONOMY.maxLine2Stops
    ) {
      const current =
        WORLD.line2Stops[
          state.line2.stopCount - 1
        ];

      const next =
        WORLD.line2Stops[
          state.line2.stopCount
        ];

      const ghostRoute = routeMetrics([
        { x: current.x, y: current.y },
        { x: next.x, y: next.y },
      ]);

      this.#drawGhostLine(
        ctx,
        ghostRoute,
        LINE_2_COLOR,
      );

      this.#drawFutureStop(
        ctx,
        next,
        STOP_NAMES.line2[
          state.line2.stopCount
        ],
        getNextStopCost(
          state,
          'line2',
        ),
        LINE_2_COLOR,
        this.selected === 'futureStop2',
      );

      this.hitTargets.push({
        id: 'futureStop2',
        rect: {
          ...next,
          w: 86,
          h: 86,
        },
      });
    }

    if (
      state.line2.queuePassengers > 0
    ) {
      const firstNewStop =
        WORLD.line2Stops[1];

      this.#drawPassengerQueue(
        ctx,
        firstNewStop.x - 65,
        firstNewStop.y + 53,
        state.line2.queuePassengers,
        state.line2.waitingCapacityPassengers,
      );
    }
  }

  #traceRoute(ctx, metrics) {
    ctx.beginPath();

    ctx.moveTo(
      metrics.points[0].x,
      metrics.points[0].y,
    );

    for (
      let index = 1;
      index < metrics.points.length;
      index += 1
    ) {
      ctx.lineTo(
        metrics.points[index].x,
        metrics.points[index].y,
      );
    }
  }

  #drawTransitLine(
    ctx,
    metrics,
    color,
    lineNumber,
  ) {
    if (metrics.points.length < 2) return;

    ctx.save();
    ctx.lineJoin = 'round';
    ctx.lineCap = 'round';

    ctx.strokeStyle = '#050505';
    ctx.lineWidth = 15;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = color;
    ctx.lineWidth = 10;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = '#171717';
    ctx.lineWidth = 4;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    for (
      let distance = 18;
      distance < metrics.total;
      distance += 48
    ) {
      const point =
        pointOnRoute(metrics, distance);

      ctx.fillStyle = '#121212';
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;

      ctx.beginPath();
      ctx.arc(
        point.x,
        point.y,
        7,
        0,
        Math.PI * 2,
      );
      ctx.fill();
      ctx.stroke();

      ctx.fillStyle = '#f0efe8';
      ctx.font =
        '7px "Lucida Console", monospace';
      ctx.textAlign = 'center';

      ctx.fillText(
        String(lineNumber),
        point.x,
        point.y + 2.5,
      );
    }

    ctx.restore();
  }

  #drawGhostLine(
    ctx,
    metrics,
    color,
  ) {
    if (metrics.points.length < 2) return;

    ctx.save();
    ctx.setLineDash([6, 8]);
    ctx.lineCap = 'round';

    ctx.strokeStyle = '#303030';
    ctx.lineWidth = 12;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.strokeStyle = color;
    ctx.globalAlpha = 0.48;
    ctx.lineWidth = 3;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();

    ctx.restore();
  }

  #drawServiceSpur(
    ctx,
    metrics,
    color,
  ) {
    ctx.save();
    ctx.setLineDash([4, 4]);
    ctx.strokeStyle = color;
    ctx.lineWidth = 3;
    this.#traceRoute(ctx, metrics);
    ctx.stroke();
    ctx.restore();
  }

  #drawVehicles(
    ctx,
    metrics,
    fleetCount,
    color,
    mode,
  ) {
    if (
      fleetCount <= 0
      || metrics.total <= 0
    ) {
      return;
    }

    const modeConfig =
      TRANSPORT_MODES[mode]
      ?? TRANSPORT_MODES.bus;

    const speed =
      26 + modeConfig.speedKph * 0.32;

    for (
      let index = 0;
      index < fleetCount;
      index += 1
    ) {
      const point = pointOnRoute(
        metrics,
        this.time * speed
          + index / fleetCount
            * metrics.total,
      );

      this.#drawBus(
        ctx,
        point,
        color,
      );
    }
  }

  #drawBus(ctx, point, color) {
    const angle =
      Math.atan2(point.ty, point.tx);

    ctx.save();

    ctx.translate(
      Math.round(point.x),
      Math.round(point.y),
    );

    ctx.rotate(angle);

    ctx.fillStyle = '#050505';
    ctx.fillRect(-10, -6, 20, 12);

    ctx.fillStyle = color;
    ctx.fillRect(-9, -5, 18, 10);

    ctx.fillStyle = '#d9f6ff';
    ctx.fillRect(-6, -4, 4, 4);
    ctx.fillRect(1, -4, 4, 4);

    ctx.fillStyle = '#111';
    ctx.fillRect(-7, 5, 4, 2);
    ctx.fillRect(3, 5, 4, 2);

    ctx.restore();
  }

  #drawStop(
    ctx,
    rect,
    label,
    number,
    color,
    selected,
    origin,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        color,
      );
    }

    const width = origin ? 48 : 38;
    const height = origin ? 50 : 42;

    ctx.fillStyle = '#050505';

    ctx.fillRect(
      x - width / 2 - 3,
      y - height / 2 - 3,
      width + 6,
      height + 6,
    );

    ctx.fillStyle = '#efeee8';

    ctx.fillRect(
      x - width / 2,
      y - height / 2,
      width,
      height,
    );

    ctx.fillStyle = '#2b2b2b';

    ctx.fillRect(
      x - width / 2 + 6,
      y - height / 2 + 6,
      width - 12,
      height - 12,
    );

    ctx.fillStyle = color;

    ctx.fillRect(
      x - 4,
      y - 15,
      8,
      20,
    );

    ctx.fillStyle = '#f3f2eb';
    ctx.font =
      '8px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      String(number),
      x,
      y - 22,
    );

    ctx.fillText(
      label.toUpperCase(),
      x,
      y + height / 2 + 16,
    );
  }

  #drawFutureStop(
    ctx,
    rect,
    label,
    cost,
    color,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        {
          ...rect,
          w: 72,
          h: 72,
        },
        color,
      );
    }

    ctx.save();
    ctx.globalAlpha = 0.64;
    ctx.setLineDash([5, 5]);
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;

    ctx.strokeRect(
      x - 22,
      y - 25,
      44,
      50,
    );

    ctx.restore();

    ctx.fillStyle = '#777';
    ctx.font =
      '8px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      label.toUpperCase(),
      x,
      y + 39,
    );

    ctx.fillStyle = '#f4ca00';

    ctx.fillText(
      `$${cost}`,
      x,
      y + 51,
    );
  }

  #drawFutureDepot(
    ctx,
    rect,
    cost,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        '#efeee8',
      );
    }

    ctx.save();
    ctx.globalAlpha = 0.55;
    ctx.setLineDash([6, 5]);
    ctx.strokeStyle = '#efeee8';
    ctx.lineWidth = 2;

    ctx.strokeRect(
      x - 55,
      y - 38,
      110,
      76,
    );

    ctx.restore();

    ctx.fillStyle = '#b8b8b1';
    ctx.font =
      '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      'BUS DEPOT',
      x,
      y - 3,
    );

    ctx.fillStyle = '#f4ca00';

    ctx.fillText(
      `UNLOCKED · $${cost}`,
      x,
      y + 14,
    );
  }

  #drawDepotBuilding(
    ctx,
    rect,
    state,
    selected,
  ) {
    const { x, y } = rect;

    if (selected) {
      this.#drawSelection(
        ctx,
        rect,
        '#efeee8',
      );
    }

    ctx.fillStyle = '#050505';
    ctx.fillRect(
      x - 59,
      y - 43,
      118,
      86,
    );

    ctx.fillStyle = '#efeee8';
    ctx.fillRect(
      x - 54,
      y - 38,
      108,
      76,
    );

    ctx.fillStyle = '#555954';
    ctx.fillRect(
      x - 47,
      y - 31,
      94,
      62,
    );

    const used =
      state.line1.fleetCount
      + state.line2.fleetCount;

    const slots = Math.min(
      state.depot.garageSlots,
      8,
    );

    for (
      let index = 0;
      index < slots;
      index += 1
    ) {
      const col = index % 4;
      const row = Math.floor(index / 4);

      const px =
        x - 36 + col * 24;

      const py =
        y - 16 + row * 27;

      ctx.fillStyle =
        index < used
          ? '#0797ec'
          : '#232323';

      ctx.fillRect(
        px,
        py,
        15,
        9,
      );

      ctx.strokeStyle = '#111';
      ctx.strokeRect(
        px,
        py,
        15,
        9,
      );
    }

    ctx.fillStyle = '#efeee8';
    ctx.font =
      '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      'BUS DEPOT',
      x,
      y + 57,
    );
  }

  #drawFutureLine(
    ctx,
    rect,
    cost,
    selected,
  ) {
    if (selected) {
      this.#drawSelection(
        ctx,
        {
          ...rect,
          w: 96,
          h: 86,
        },
        LINE_2_COLOR,
      );
    }

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = LINE_2_COLOR;
    ctx.lineWidth = 2;

    ctx.fillRect(
      rect.x - 47,
      rect.y - 27,
      94,
      54,
    );

    ctx.strokeRect(
      rect.x - 47,
      rect.y - 27,
      94,
      54,
    );

    ctx.fillStyle = '#efeee8';
    ctx.font =
      '9px "Lucida Console", monospace';
    ctx.textAlign = 'center';

    ctx.fillText(
      'NEW BUS LINE',
      rect.x,
      rect.y - 5,
    );

    ctx.fillStyle = '#f4ca00';

    ctx.fillText(
      `LINE 2 · $${cost}`,
      rect.x,
      rect.y + 12,
    );
  }

  #drawPassengerQueue(
    ctx,
    x,
    y,
    waiting,
    capacity,
  ) {
    const ratio =
      capacity > 0
        ? clamp(
          waiting / capacity,
          0,
          1,
        )
        : 0;

    const color =
      ratio >= 0.9
        ? '#e91e47'
        : ratio >= 0.5
          ? '#f4ca00'
          : '#efeee8';

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;

    ctx.fillRect(
      x,
      y,
      132,
      33,
    );

    ctx.strokeRect(
      x,
      y,
      132,
      33,
    );

    const people = clamp(
      Math.ceil(ratio * 10),
      0,
      10,
    );

    for (
      let index = 0;
      index < 10;
      index += 1
    ) {
      const px =
        x + 10 + index * 10;

      ctx.fillStyle =
        index < people
          ? color
          : '#333';

      ctx.fillRect(
        px,
        y + 8,
        4,
        4,
      );

      ctx.fillRect(
        px - 1,
        y + 13,
        6,
        7,
      );
    }

    ctx.fillStyle = '#efeee8';
    ctx.font =
      '8px "Lucida Console", monospace';
    ctx.textAlign = 'left';

    ctx.fillText(
      `WAITING ${waiting.toFixed(0)}`,
      x + 8,
      y + 29,
    );
  }

  #drawRevenuePulse(
    ctx,
    state,
    lastStop,
  ) {
    const income =
      getIncomePerSecond(state);

    if (income <= 0) return;

    const phase =
      this.time % 2.2;

    const alpha = clamp(
      1 - phase / 2.2,
      0.15,
      1,
    );

    ctx.globalAlpha = alpha;

    ctx.fillStyle = '#ffe000';
    ctx.beginPath();

    ctx.arc(
      lastStop.x + 42,
      lastStop.y - phase * 8,
      7,
      0,
      Math.PI * 2,
    );

    ctx.fill();

    ctx.fillStyle = '#b9ff8b';
    ctx.font =
      '10px "Lucida Console", monospace';

    ctx.fillText(
      `+${income.toFixed(1)}`,
      lastStop.x + 54,
      lastStop.y + 3 - phase * 8,
    );

    ctx.globalAlpha = 1;
  }

  #drawSystemReadout(ctx, state) {
    if (!state.line1.built) return;

    const delivered =
      getDeliveredPassengersPpm(state);

    const wait =
      getAverageWaitMinutes(state);

    const bottleneck =
      getBottleneck(state);

    const x = -35;
    const y = -250;

    ctx.fillStyle = '#151515';
    ctx.strokeStyle = '#4e4e4e';
    ctx.lineWidth = 2;

    ctx.fillRect(
      x - 105,
      y - 18,
      210,
      52,
    );

    ctx.strokeRect(
      x - 105,
      y - 18,
      210,
      52,
    );

    ctx.fillStyle = '#efeee8';
    ctx.font =
      '9px "Lucida Console", monospace';
    ctx.textAlign = 'left';

    ctx.fillText(
      `DELIVERED ${delivered.toFixed(1)} pax/min`,
      x - 95,
      y,
    );

    ctx.fillStyle =
      wait > 5
        ? '#f4ca00'
        : '#aaa9a2';

    ctx.fillText(
      `AVG WAIT ${wait.toFixed(1)} min`,
      x - 95,
      y + 14,
    );

    ctx.fillStyle =
      bottleneck === 'none'
        ? '#aaa9a2'
        : '#e91e47';

    ctx.fillText(
      `STATUS ${bottleneck.toUpperCase()}`,
      x - 95,
      y + 28,
    );
  }

  #drawSelection(
    ctx,
    rect,
    color,
  ) {
    ctx.save();

    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.setLineDash([5, 4]);

    ctx.strokeRect(
      rect.x - rect.w / 2 - 8,
      rect.y - rect.h / 2 - 8,
      rect.w + 16,
      rect.h + 16,
    );

    ctx.restore();
  }
}
