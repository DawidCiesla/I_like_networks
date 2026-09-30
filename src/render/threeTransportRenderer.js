import * as THREE from 'three';
import {
  OrbitControls,
} from 'three/addons/controls/OrbitControls.js';

import {
  ECONOMY,
  STOP_NAMES,
  canBuildDepot,
  canUnlockLine2,
  getNextStopCost,
} from '../simulation/model.js';

import {
  WORLD,
  getBuiltRoute,
  getDepotSpurRoute,
  getFutureSegmentRoute,
  getVehiclePoint,
} from './transportLayout.js';

import {
  closestPointOnRoad,
} from '../city/roadTopology.js';

import {
  terrainBiome,
  terrainColorSample,
  terrainForestPotential,
  terrainHeight,
} from '../world/terrainModel.js';

const LINE_1_COLOR = 0x0797ec;
const LINE_2_COLOR = 0xf4ca00;

const ROAD_COLORS = Object.freeze({
  arterial: 0x34383a,
  collector: 0x3a3d3c,
  local: 0x404240,
  service: 0x454641,
});

const ROAD_WIDTHS = Object.freeze({
  arterial: 31,
  collector: 21,
  local: 15,
  service: 12,
});

const SIDEWALK_WIDTHS = Object.freeze({
  arterial: 42,
  collector: 31,
  local: 23,
  service: 19,
});

const BUILDING_COLORS = Object.freeze({
  residential: 0xb5a98e,
  mixed: 0x9f9a88,
  commercial: 0xb8aa7c,
  civic: 0xa4aaa9,
  industrial: 0x8d8d82,
});

const clamp = (
  value,
  min,
  max,
) => Math.min(
  max,
  Math.max(min, value),
);

function disposeObject(object) {
  object.traverse((child) => {
    child.geometry?.dispose?.();

    if (Array.isArray(child.material)) {
      for (const material of child.material) {
        material?.map?.dispose?.();
        material?.dispose?.();
      }
      return;
    }

    child.material?.map?.dispose?.();
    child.material?.dispose?.();
  });
}

function clearGroup(group) {
  for (
    let index = group.children.length - 1;
    index >= 0;
    index -= 1
  ) {
    const child =
      group.children[index];

    group.remove(child);
    disposeObject(child);
  }
}

function pseudoRandom(
  seed,
  x,
  z,
  channel = 0,
) {
  const value =
    Math.sin(
      x * 12.9898
      + z * 78.233
      + seed * 0.00317
      + channel * 19.19,
    ) * 43758.5453;

  return value - Math.floor(value);
}

function worldBounds(state) {
  const points = [];

  for (const road of state.city.roads) {
    points.push(...road.points);
  }

  for (const reservation of state.city.reservations ?? []) {
    points.push(
      {
        x:
          reservation.x
          - reservation.w / 2,
        y:
          reservation.y
          - reservation.h / 2,
      },
      {
        x:
          reservation.x
          + reservation.w / 2,
        y:
          reservation.y
          + reservation.h / 2,
      },
    );
  }

  points.push(
    ...WORLD.line1Stops,
    ...WORLD.line2Stops,
    WORLD.depot,
  );

  const margin = 720;

  return {
    minX:
      Math.min(
        ...points.map(
          (point) => point.x,
        ),
      ) - margin,
    maxX:
      Math.max(
        ...points.map(
          (point) => point.x,
        ),
      ) + margin,
    minZ:
      Math.min(
        ...points.map(
          (point) => point.y,
        ),
      ) - margin,
    maxZ:
      Math.max(
        ...points.map(
          (point) => point.y,
        ),
      ) + margin,
  };
}

function samplePolyline(
  points,
  maxStep = 22,
) {
  if (points.length < 2) {
    return points.map(
      (point) => ({
        ...point,
      }),
    );
  }

  const sampled = [
    {
      ...points[0],
    },
  ];

  for (
    let index = 0;
    index < points.length - 1;
    index += 1
  ) {
    const a =
      points[index];

    const b =
      points[index + 1];

    const length =
      Math.hypot(
        b.x - a.x,
        b.y - a.y,
      );

    const steps =
      Math.max(
        1,
        Math.ceil(
          length / maxStep,
        ),
      );

    for (
      let step = 1;
      step <= steps;
      step += 1
    ) {
      const t =
        step / steps;

      sampled.push({
        x:
          a.x
          + (b.x - a.x) * t,
        y:
          a.y
          + (b.y - a.y) * t,
      });
    }
  }

  return sampled;
}

function polylinePrefix(
  points,
  progress,
) {
  const clamped =
    clamp(
      progress,
      0,
      1,
    );

  if (clamped >= 1) {
    return points.map(
      (point) => ({
        ...point,
      }),
    );
  }

  if (
    clamped <= 0
    || points.length < 2
  ) {
    return [];
  }

  const lengths = [];
  let total = 0;

  for (
    let index = 0;
    index < points.length - 1;
    index += 1
  ) {
    const length =
      Math.hypot(
        points[index + 1].x
          - points[index].x,
        points[index + 1].y
          - points[index].y,
      );

    lengths.push(length);
    total += length;
  }

  const target =
    total * clamped;

  const result = [
    {
      ...points[0],
    },
  ];

  let travelled = 0;

  for (
    let index = 0;
    index < lengths.length;
    index += 1
  ) {
    const length =
      lengths[index];

    if (
      travelled + length
      <= target
    ) {
      result.push({
        ...points[index + 1],
      });

      travelled += length;
      continue;
    }

    const remaining =
      target - travelled;

    const local =
      length <= 1e-9
        ? 0
        : remaining / length;

    result.push({
      x:
        points[index].x
        + (
          points[index + 1].x
          - points[index].x
        ) * local,
      y:
        points[index].y
        + (
          points[index + 1].y
          - points[index].y
        ) * local,
    });

    break;
  }

  return result;
}

function ribbonGeometry(
  seed,
  points,
  width,
  elevation,
) {
  const sampled =
    samplePolyline(
      points,
      20,
    );

  if (sampled.length < 2) {
    return null;
  }

  const vertices = [];
  const indices = [];

  for (
    let index = 0;
    index < sampled.length;
    index += 1
  ) {
    const previous =
      sampled[
        Math.max(
          0,
          index - 1,
        )
      ];

    const next =
      sampled[
        Math.min(
          sampled.length - 1,
          index + 1,
        )
      ];

    const dx =
      next.x - previous.x;

    const dz =
      next.y - previous.y;

    const length =
      Math.hypot(dx, dz)
      || 1;

    const nx =
      -dz / length;

    const nz =
      dx / length;

    for (
      const side of [-1, 1]
    ) {
      const x =
        sampled[index].x
        + nx * width * 0.5 * side;

      const z =
        sampled[index].y
        + nz * width * 0.5 * side;

      const y =
        terrainHeight(
          seed,
          x,
          z,
        ) + elevation;

      vertices.push(
        x,
        y,
        z,
      );
    }

    if (index > 0) {
      const base =
        index * 2;

      indices.push(
        base - 2,
        base - 1,
        base,
        base - 1,
        base + 1,
        base,
      );
    }
  }

  const geometry =
    new THREE.BufferGeometry();

  geometry.setAttribute(
    'position',
    new THREE.Float32BufferAttribute(
      vertices,
      3,
    ),
  );

  geometry.setIndex(indices);
  geometry.computeVertexNormals();

  return geometry;
}

function lineGeometry(
  seed,
  points,
  elevation = 1.2,
) {
  const sampled =
    samplePolyline(
      points,
      18,
    );

  const vertices =
    sampled.flatMap(
      (point) => [
        point.x,
        terrainHeight(
          seed,
          point.x,
          point.y,
        ) + elevation,
        point.y,
      ],
    );

  const geometry =
    new THREE.BufferGeometry();

  geometry.setAttribute(
    'position',
    new THREE.Float32BufferAttribute(
      vertices,
      3,
    ),
  );

  return geometry;
}

function linePointsFromMetrics(metrics) {
  return metrics?.points?.map(
    (point) => ({
      x: point.x,
      y: point.y,
    }),
  ) ?? [];
}

function buildingDimensions(
  parcel,
  building,
) {
  const inset =
    Math.max(
      4,
      parcel.setback ?? 6,
    );

  return {
    width:
      Math.max(
        14,
        parcel.w - inset * 1.4,
      ),
    depth:
      Math.max(
        12,
        parcel.h - inset * 1.4,
      ),
    height:
      building.profile
        ?.heightMeters
      ?? Math.max(
        6,
        (
          building.profile?.floors
          ?? 1
        ) * 3.2,
      ),
  };
}

function labelCanvas(
  text,
  {
    foreground = '#f0f0e8',
    background =
      'rgba(18,18,18,0.84)',
    accent = '#7a7a72',
  } = {},
) {
  const canvas =
    document.createElement(
      'canvas',
    );

  canvas.width = 512;
  canvas.height = 96;

  const ctx =
    canvas.getContext('2d');

  ctx.imageSmoothingEnabled = false;

  ctx.fillStyle =
    background;

  ctx.fillRect(
    0,
    0,
    canvas.width,
    canvas.height,
  );

  ctx.strokeStyle = accent;
  ctx.lineWidth = 4;

  ctx.strokeRect(
    2,
    2,
    canvas.width - 4,
    canvas.height - 4,
  );

  ctx.fillStyle =
    foreground;

  ctx.font =
    '28px monospace';

  ctx.textAlign = 'center';
  ctx.textBaseline = 'middle';

  ctx.fillText(
    String(text).toUpperCase(),
    canvas.width / 2,
    canvas.height / 2,
  );

  return canvas;
}

function textSprite(
  text,
  options = {},
) {
  const texture =
    new THREE.CanvasTexture(
      labelCanvas(
        text,
        options,
      ),
    );

  texture.colorSpace =
    THREE.SRGBColorSpace;

  const material =
    new THREE.SpriteMaterial({
      map: texture,
      transparent: true,
      depthWrite: false,
    });

  const sprite =
    new THREE.Sprite(
      material,
    );

  sprite.scale.set(
    options.width ?? 115,
    options.height ?? 22,
    1,
  );

  return sprite;
}

function materialForBuilding(
  building,
) {
  const color =
    BUILDING_COLORS[
      building.zone
    ] ?? 0xa09b88;

  return new THREE.MeshStandardMaterial({
    color:
      building.status
        === 'built'
          ? color
          : 0x777872,
    roughness: 0.92,
    metalness:
      building.zone === 'industrial'
        ? 0.12
        : 0.03,
  });
}

function roadParentsBuilt(
  state,
  road,
) {
  const parents =
    road.parentRoadIds ?? [];

  return parents.every(
    (parentId) =>
      state.city.roads.some(
        (candidate) =>
          candidate.id === parentId
          && candidate.status === 'built',
      ),
  );
}

function rectangleContains(
  rectangle,
  x,
  z,
  padding = 0,
) {
  return (
    x
      >= rectangle.x
        - rectangle.w / 2
        - padding
    && x
      <= rectangle.x
        + rectangle.w / 2
        + padding
    && z
      >= rectangle.y
        - rectangle.h / 2
        - padding
    && z
      <= rectangle.y
        + rectangle.h / 2
        + padding
  );
}

function pointNearRoad(
  point,
  road,
  extra = 0,
) {
  const closest =
    closestPointOnRoad(
      {
        x: point.x,
        y: point.z,
      },
      road,
    );

  if (!closest) {
    return false;
  }

  const width =
    ROAD_WIDTHS[
      road.class
    ] ?? 15;

  return (
    closest.distance
    < width * 0.5
      + extra
  );
}

export class ThreeTransportRenderer {
  constructor(
    canvas,
    {
      onSelectionChanged,
    } = {},
  ) {
    this.canvas = canvas;
    this.onSelectionChanged =
      onSelectionChanged;

    this.renderer =
      new THREE.WebGLRenderer({
        canvas,
        antialias: true,
        alpha: false,
        powerPreference:
          'high-performance',
      });

    this.renderer.outputColorSpace =
      THREE.SRGBColorSpace;

    this.renderer.toneMapping =
      THREE.ACESFilmicToneMapping;

    this.renderer.toneMappingExposure =
      1.06;

    this.renderer.shadowMap.enabled =
      true;

    this.renderer.shadowMap.type =
      THREE.PCFSoftShadowMap;

    this.scene =
      new THREE.Scene();

    this.scene.background =
      new THREE.Color(
        0x111713,
      );

    this.scene.fog =
      new THREE.FogExp2(
        0x111713,
        0.00022,
      );

    this.camera =
      new THREE.PerspectiveCamera(
        46,
        1,
        1,
        12000,
      );

    this.controls =
      new OrbitControls(
        this.camera,
        this.canvas,
      );

    this.controls.enableDamping =
      true;

    this.controls.dampingFactor =
      0.08;

    this.controls.screenSpacePanning =
      false;

    this.controls.minDistance =
      120;

    this.controls.maxDistance =
      5200;

    this.controls.minPolarAngle =
      Math.PI * 0.12;

    this.controls.maxPolarAngle =
      Math.PI * 0.47;

    this.controls.mouseButtons = {
      LEFT: THREE.MOUSE.ROTATE,
      MIDDLE: THREE.MOUSE.DOLLY,
      RIGHT: THREE.MOUSE.PAN,
    };

    this.controls.touches = {
      ONE: THREE.TOUCH.ROTATE,
      TWO:
        THREE.TOUCH.DOLLY_PAN,
    };

    this.root =
      new THREE.Group();

    this.terrainGroup =
      new THREE.Group();

    this.natureGroup =
      new THREE.Group();

    this.roadGroup =
      new THREE.Group();

    this.buildingGroup =
      new THREE.Group();

    this.transportGroup =
      new THREE.Group();

    this.vehicleGroup =
      new THREE.Group();

    this.scene.add(
      this.root,
    );

    this.root.add(
      this.terrainGroup,
      this.natureGroup,
      this.roadGroup,
      this.buildingGroup,
      this.transportGroup,
      this.vehicleGroup,
    );

    this.selectables = [];
    this.selected = null;
    this.raycaster =
      new THREE.Raycaster();

    this.pointerDown = null;
    this.worldSeed = null;
    this.bounds = null;
    this.citySignature = null;
    this.transportSignature = null;
    this.initialFocusDone = false;

    this.#addLights();
    this.#bindInput();
    this.resize();
  }

  #addLights() {
    const sky =
      new THREE.HemisphereLight(
        0xbfd6ff,
        0x34402f,
        1.35,
      );

    this.scene.add(sky);

    const sun =
      new THREE.DirectionalLight(
        0xfff2d4,
        2.2,
      );

    sun.position.set(
      -900,
      1300,
      -700,
    );

    sun.castShadow = true;

    sun.shadow.mapSize.set(
      2048,
      2048,
    );

    sun.shadow.camera.near = 50;
    sun.shadow.camera.far = 4500;
    sun.shadow.camera.left = -1800;
    sun.shadow.camera.right = 1800;
    sun.shadow.camera.top = 1800;
    sun.shadow.camera.bottom = -1800;

    this.scene.add(sun);

    const fill =
      new THREE.DirectionalLight(
        0x8fc7ff,
        0.5,
      );

    fill.position.set(
      900,
      500,
      700,
    );

    this.scene.add(fill);
  }

  #bindInput() {
    this.canvas.addEventListener(
      'contextmenu',
      (event) =>
        event.preventDefault(),
    );

    this.canvas.addEventListener(
      'pointerdown',
      (event) => {
        this.pointerDown = {
          x: event.clientX,
          y: event.clientY,
        };
      },
    );

    this.canvas.addEventListener(
      'pointerup',
      (event) => {
        if (!this.pointerDown) {
          return;
        }

        const movement =
          Math.hypot(
            event.clientX
              - this.pointerDown.x,
            event.clientY
              - this.pointerDown.y,
          );

        this.pointerDown = null;

        if (movement <= 5) {
          this.#selectAt(
            event.clientX,
            event.clientY,
          );
        }
      },
    );

    window.addEventListener(
      'resize',
      () => this.resize(),
    );
  }

  resize() {
    const rect =
      this.canvas.getBoundingClientRect();

    const dpr =
      Math.min(
        window.devicePixelRatio
          || 1,
        2,
      );

    this.renderer.setPixelRatio(
      dpr,
    );

    this.renderer.setSize(
      Math.max(1, rect.width),
      Math.max(1, rect.height),
      false,
    );

    this.camera.aspect =
      Math.max(
        1,
        rect.width,
      )
      / Math.max(
        1,
        rect.height,
      );

    this.camera.updateProjectionMatrix();
  }

  setSelection(selection) {
    this.selected = selection;
    this.transportSignature = null;
  }

  #registerSelectable(
    object,
    selection,
  ) {
    object.userData.selection =
      selection;

    this.selectables.push(
      object,
    );
  }

  #selectAt(
    clientX,
    clientY,
  ) {
    const rect =
      this.canvas.getBoundingClientRect();

    const pointer =
      new THREE.Vector2(
        (
          (clientX - rect.left)
          / rect.width
        ) * 2 - 1,
        -(
          (
            clientY - rect.top
          ) / rect.height
        ) * 2 + 1,
      );

    this.raycaster.setFromCamera(
      pointer,
      this.camera,
    );

    const intersections =
      this.raycaster.intersectObjects(
        this.selectables,
        true,
      );

    let selection = null;

    for (
      const intersection
      of intersections
    ) {
      let object =
        intersection.object;

      while (
        object
        && !object.userData.selection
      ) {
        object = object.parent;
      }

      if (
        object?.userData
          ?.selection
      ) {
        selection =
          object.userData.selection;
        break;
      }
    }

    this.selected = selection;
    this.transportSignature = null;

    this.onSelectionChanged?.(
      selection,
    );
  }

  #focusInitial(state) {
    if (this.initialFocusDone) {
      return;
    }

    const stop =
      WORLD.line1Stops[0];

    const ground =
      terrainHeight(
        state.city.seed,
        stop.x,
        stop.y,
      );

    this.controls.target.set(
      stop.x + 120,
      ground,
      stop.y - 40,
    );

    this.camera.position.set(
      stop.x + 760,
      ground + 690,
      stop.y + 980,
    );

    this.camera.lookAt(
      this.controls.target,
    );

    this.controls.update();
    this.initialFocusDone = true;
  }

  #ensureTerrain(state) {
    if (
      this.worldSeed
        === state.city.seed
      && this.bounds
    ) {
      return;
    }

    this.worldSeed =
      state.city.seed;

    this.bounds =
      worldBounds(state);

    clearGroup(
      this.terrainGroup,
    );

    this.#buildTerrain(state);
    this.citySignature = null;
  }

  #buildTerrain(state) {
    const bounds =
      this.bounds;

    const width =
      bounds.maxX
      - bounds.minX;

    const depth =
      bounds.maxZ
      - bounds.minZ;

    const centerX =
      (bounds.minX + bounds.maxX)
      / 2;

    const centerZ =
      (bounds.minZ + bounds.maxZ)
      / 2;

    const widthSegments =
      clamp(
        Math.ceil(
          width / 34,
        ),
        70,
        150,
      );

    const depthSegments =
      clamp(
        Math.ceil(
          depth / 34,
        ),
        60,
        130,
      );

    const geometry =
      new THREE.PlaneGeometry(
        width,
        depth,
        widthSegments,
        depthSegments,
      );

    const positions =
      geometry.attributes.position;

    const colors =
      new Float32Array(
        positions.count * 3,
      );

    for (
      let index = 0;
      index < positions.count;
      index += 1
    ) {
      const localX =
        positions.getX(index);

      const localPlaneY =
        positions.getY(index);

      const worldX =
        centerX + localX;

      const worldZ =
        centerZ - localPlaneY;

      const height =
        terrainHeight(
          state.city.seed,
          worldX,
          worldZ,
        );

      positions.setZ(
        index,
        height,
      );

      const color =
        terrainColorSample(
          state.city.seed,
          worldX,
          worldZ,
        );

      colors[index * 3] =
        color.r;

      colors[index * 3 + 1] =
        color.g;

      colors[index * 3 + 2] =
        color.b;
    }

    geometry.setAttribute(
      'color',
      new THREE.BufferAttribute(
        colors,
        3,
      ),
    );

    geometry.computeVertexNormals();

    const material =
      new THREE.MeshStandardMaterial({
        vertexColors: true,
        roughness: 1,
        metalness: 0,
        flatShading: false,
      });

    const terrain =
      new THREE.Mesh(
        geometry,
        material,
      );

    terrain.rotation.x =
      -Math.PI / 2;

    terrain.position.set(
      centerX,
      0,
      centerZ,
    );

    terrain.receiveShadow =
      true;

    this.terrainGroup.add(
      terrain,
    );
  }

  #cityStateSignature(state) {
    const roads =
      state.city.roads.map(
        (road) =>
          `${road.id}:${road.status}:`
          + `${Math.round((road.constructionProgress ?? 0) * 20)}`,
      ).join('|');

    const buildings =
      state.city.buildings.map(
        (building) =>
          `${building.id}:${building.status}:`
          + `${Math.round((building.constructionProgress ?? 0) * 20)}`,
      ).join('|');

    return (
      `${state.city.seed}::`
      + roads
      + '::'
      + buildings
      + `::depot:${state.depot.built}`
    );
  }

  #transportStateSignature(state) {
    return [
      state.line1.built,
      state.line1.stopCount,
      state.line1.fleetCount,
      state.line2.built,
      state.line2.stopCount,
      state.line2.fleetCount,
      state.depot.built,
      this.selected,
    ].join(':');
  }

  #syncCity(state) {
    const signature =
      this.#cityStateSignature(
        state,
      );

    if (
      signature
      === this.citySignature
    ) {
      return;
    }

    this.citySignature =
      signature;

    clearGroup(
      this.roadGroup,
    );

    clearGroup(
      this.buildingGroup,
    );

    clearGroup(
      this.natureGroup,
    );

    this.#buildNature(state);
    this.#buildRoads(state);
    this.#buildBuildings(state);
  }

  #buildNature(state) {
    const bounds =
      this.bounds;

    const trees = [];

    const spacing = 72;

    for (
      let x =
        bounds.minX + spacing;
      x <= bounds.maxX - spacing;
      x += spacing
    ) {
      for (
        let z =
          bounds.minZ + spacing;
        z <= bounds.maxZ - spacing;
        z += spacing
      ) {
        const jitterX =
          (
            pseudoRandom(
              state.city.seed,
              x,
              z,
              1,
            ) - 0.5
          ) * spacing * 0.72;

        const jitterZ =
          (
            pseudoRandom(
              state.city.seed,
              x,
              z,
              2,
            ) - 0.5
          ) * spacing * 0.72;

        const px =
          x + jitterX;

        const pz =
          z + jitterZ;

        const forest =
          terrainForestPotential(
            state.city.seed,
            px,
            pz,
          );

        const biome =
          terrainBiome(
            state.city.seed,
            px,
            pz,
          );

        const threshold =
          biome === 'forest'
            ? 0.45
            : biome === 'hillside'
              ? 0.73
              : 0.9;

        if (
          forest < 0.56
          || pseudoRandom(
            state.city.seed,
            px,
            pz,
            3,
          ) < threshold
        ) {
          continue;
        }

        const blockedByFacility =
          (
            state.city.reservations
              ?? []
          ).some(
            (reservation) =>
              reservation.facilityType
                !== 'park'
              && rectangleContains(
                reservation,
                px,
                pz,
                reservation.padding
                  ?? 0,
              ),
          );

        if (blockedByFacility) {
          continue;
        }

        const blockedByRoad =
          state.city.roads.some(
            (road) =>
              (
                road.status === 'built'
                || road.status
                  === 'constructing'
              )
              && pointNearRoad(
                {
                  x: px,
                  z: pz,
                },
                road,
                13,
              ),
          );

        if (blockedByRoad) {
          continue;
        }

        const blockedByBuilding =
          state.city.buildings.some(
            (building) => {
              const parcel =
                state.city.parcels.find(
                  (candidate) =>
                    candidate.id
                    === building.parcelId,
                );

              if (!parcel) {
                return false;
              }

              return rectangleContains(
                {
                  x: parcel.x,
                  y: parcel.y,
                  w: parcel.w,
                  h: parcel.h,
                },
                px,
                pz,
                8,
              );
            },
          );

        if (blockedByBuilding) {
          continue;
        }

        trees.push({
          x: px,
          z: pz,
          scale:
            0.75
            + pseudoRandom(
              state.city.seed,
              px,
              pz,
              4,
            ) * 0.8,
        });
      }
    }

    if (trees.length === 0) {
      return;
    }

    const trunkGeometry =
      new THREE.CylinderGeometry(
        1.6,
        2.1,
        11,
        6,
      );

    const trunkMaterial =
      new THREE.MeshStandardMaterial({
        color: 0x5e4d34,
        roughness: 1,
      });

    const crownGeometry =
      new THREE.ConeGeometry(
        9,
        23,
        7,
      );

    const crownMaterial =
      new THREE.MeshStandardMaterial({
        color: 0x315b31,
        roughness: 1,
      });

    const trunks =
      new THREE.InstancedMesh(
        trunkGeometry,
        trunkMaterial,
        trees.length,
      );

    const crowns =
      new THREE.InstancedMesh(
        crownGeometry,
        crownMaterial,
        trees.length,
      );

    trunks.castShadow = true;
    trunks.receiveShadow = true;
    crowns.castShadow = true;

    const dummy =
      new THREE.Object3D();

    trees.forEach(
      (tree, index) => {
        const ground =
          terrainHeight(
            state.city.seed,
            tree.x,
            tree.z,
          );

        dummy.position.set(
          tree.x,
          ground
            + 5.5 * tree.scale,
          tree.z,
        );

        dummy.scale.set(
          tree.scale,
          tree.scale,
          tree.scale,
        );

        dummy.rotation.y =
          pseudoRandom(
            state.city.seed,
            tree.x,
            tree.z,
            5,
          ) * Math.PI * 2;

        dummy.updateMatrix();

        trunks.setMatrixAt(
          index,
          dummy.matrix,
        );

        dummy.position.y =
          ground
          + 18.5 * tree.scale;

        dummy.updateMatrix();

        crowns.setMatrixAt(
          index,
          dummy.matrix,
        );
      },
    );

    trunks.instanceMatrix.needsUpdate =
      true;

    crowns.instanceMatrix.needsUpdate =
      true;

    this.natureGroup.add(
      trunks,
      crowns,
    );
  }

  #addRoadMesh(
    state,
    road,
    points,
  ) {
    if (points.length < 2) {
      return;
    }

    const sidewalkGeometry =
      ribbonGeometry(
        state.city.seed,
        points,
        SIDEWALK_WIDTHS[
          road.class
        ] ?? 23,
        0.34,
      );

    const roadGeometry =
      ribbonGeometry(
        state.city.seed,
        points,
        ROAD_WIDTHS[
          road.class
        ] ?? 15,
        0.58,
      );

    if (
      !sidewalkGeometry
      || !roadGeometry
    ) {
      return;
    }

    const sidewalk =
      new THREE.Mesh(
        sidewalkGeometry,
        new THREE.MeshStandardMaterial({
          color: 0x777a74,
          roughness: 1,
        }),
      );

    sidewalk.receiveShadow =
      true;

    const surface =
      new THREE.Mesh(
        roadGeometry,
        new THREE.MeshStandardMaterial({
          color:
            ROAD_COLORS[
              road.class
            ] ?? 0x404240,
          roughness: 0.94,
        }),
      );

    surface.receiveShadow =
      true;

    this.roadGroup.add(
      sidewalk,
      surface,
    );
  }

  #buildRoads(state) {
    for (
      const road
      of state.city.roads
    ) {
      if (
        road.status === 'built'
      ) {
        this.#addRoadMesh(
          state,
          road,
          road.points,
        );

        continue;
      }

      if (
        road.status
          === 'constructing'
      ) {
        const points =
          polylinePrefix(
            road.points,
            road.constructionProgress
              ?? 0,
          );

        this.#addRoadMesh(
          state,
          road,
          points,
        );

        continue;
      }

      const district =
        state.city.districts.find(
          (candidate) =>
            candidate.id
            === road.districtId,
        );

      const plannedVisible =
        road.source === 'city'
        && district?.status
          === 'active'
        && roadParentsBuilt(
          state,
          road,
        );

      if (!plannedVisible) {
        continue;
      }

      const geometry =
        lineGeometry(
          state.city.seed,
          road.points,
          0.75,
        );

      const material =
        new THREE.LineDashedMaterial({
          color: 0x92968e,
          transparent: true,
          opacity: 0.5,
          dashSize: 9,
          gapSize: 8,
        });

      const line =
        new THREE.Line(
          geometry,
          material,
        );

      line.computeLineDistances();
      this.roadGroup.add(line);
    }

    for (
      const junction
      of state.city.junctions ?? []
    ) {
      const builtRoads =
        junction.roadIds
          .map(
            (roadId) =>
              state.city.roads.find(
                (road) =>
                  road.id === roadId,
              ),
          )
          .filter(
            (road) =>
              road?.status === 'built',
          );

      if (builtRoads.length < 2) {
        continue;
      }

      const sidewalkRadius =
        Math.max(
          ...builtRoads.map(
            (road) =>
              (
                SIDEWALK_WIDTHS[
                  road.class
                ] ?? 23
              ) * 0.52,
          ),
        );

      const roadRadius =
        Math.max(
          ...builtRoads.map(
            (road) =>
              (
                ROAD_WIDTHS[
                  road.class
                ] ?? 15
              ) * 0.52,
          ),
        );

      const ground =
        terrainHeight(
          state.city.seed,
          junction.x,
          junction.y,
        );

      const sidewalk =
        new THREE.Mesh(
          new THREE.CylinderGeometry(
            sidewalkRadius,
            sidewalkRadius,
            0.45,
            20,
          ),
          new THREE.MeshStandardMaterial({
            color: 0x777a74,
            roughness: 1,
          }),
        );

      sidewalk.position.set(
        junction.x,
        ground + 0.34,
        junction.y,
      );

      sidewalk.receiveShadow = true;

      const surface =
        new THREE.Mesh(
          new THREE.CylinderGeometry(
            roadRadius,
            roadRadius,
            0.48,
            20,
          ),
          new THREE.MeshStandardMaterial({
            color: 0x3b3d3b,
            roughness: 0.96,
          }),
        );

      surface.position.set(
        junction.x,
        ground + 0.6,
        junction.y,
      );

      surface.receiveShadow = true;

      this.roadGroup.add(
        sidewalk,
        surface,
      );
    }
  }

  #buildingRotation(
    state,
    parcel,
  ) {
    const road =
      state.city.roads.find(
        (candidate) =>
          candidate.id
          === parcel.frontageRoadId,
      );

    if (!road) {
      return 0;
    }

    const closest =
      closestPointOnRoad(
        parcel,
        road,
      );

    if (!closest) {
      return 0;
    }

    const a =
      road.points[
        closest.segmentIndex
      ];

    const b =
      road.points[
        closest.segmentIndex + 1
      ];

    return -Math.atan2(
      b.y - a.y,
      b.x - a.x,
    );
  }

  #buildBuildings(state) {
    for (
      const building
      of state.city.buildings
    ) {
      const parcel =
        state.city.parcels.find(
          (candidate) =>
            candidate.id
            === building.parcelId,
        );

      if (!parcel) {
        continue;
      }

      const dimensions =
        buildingDimensions(
          parcel,
          building,
        );

      const progress =
        building.status === 'built'
          ? 1
          : clamp(
            building
              .constructionProgress
              ?? 0,
            0.04,
            1,
          );

      const visibleHeight =
        Math.max(
          1.2,
          dimensions.height
            * progress,
        );

      const geometry =
        new THREE.BoxGeometry(
          dimensions.width,
          visibleHeight,
          dimensions.depth,
        );

      const material =
        materialForBuilding(
          building,
        );

      const mesh =
        new THREE.Mesh(
          geometry,
          material,
        );

      const ground =
        terrainHeight(
          state.city.seed,
          building.x,
          building.y,
        );

      mesh.position.set(
        building.x,
        ground
          + visibleHeight / 2
          + 0.7,
        building.y,
      );

      mesh.rotation.y =
        Number.isFinite(
          building.rotationRadians,
        )
          ? -building.rotationRadians
          : this.#buildingRotation(
            state,
            parcel,
          );

      mesh.castShadow = true;
      mesh.receiveShadow = true;

      if (
        building.status
          !== 'built'
      ) {
        material.transparent = true;
        material.opacity = 0.78;
      }

      this.buildingGroup.add(
        mesh,
      );

      if (
        building.status === 'built'
        && [
          'house',
          'townhouse',
        ].includes(
          building.profile?.kind,
        )
      ) {
        const roof =
          new THREE.Mesh(
            new THREE.ConeGeometry(
              Math.max(
                dimensions.width,
                dimensions.depth,
              ) * 0.58,
              5.5,
              4,
            ),
            new THREE.MeshStandardMaterial({
              color: 0x654a3b,
              roughness: 1,
            }),
          );

        roof.position.copy(
          mesh.position,
        );

        roof.position.y =
          ground
          + dimensions.height
          + 3.4;

        roof.rotation.y =
          mesh.rotation.y
          + Math.PI / 4;

        roof.castShadow = true;

        this.buildingGroup.add(
          roof,
        );
      }
    }
  }

  #syncTransport(state) {
    const signature =
      this.#transportStateSignature(
        state,
      );

    if (
      signature
      === this.transportSignature
    ) {
      return;
    }

    this.transportSignature =
      signature;

    clearGroup(
      this.transportGroup,
    );

    this.selectables = [];

    this.#buildLine(
      state,
      'line1',
      WORLD.line1Stops,
      STOP_NAMES.line1,
      LINE_1_COLOR,
    );

    if (state.line2.built) {
      this.#buildLine(
        state,
        'line2',
        WORLD.line2Stops,
        STOP_NAMES.line2,
        LINE_2_COLOR,
      );
    } else if (
      canUnlockLine2(state)
    ) {
      this.#buildFutureLine2(
        state,
      );
    }

    this.#buildDepot(state);
  }

  #buildTransitRibbon(
    state,
    metrics,
    color,
    opacity = 1,
  ) {
    const points =
      linePointsFromMetrics(
        metrics,
      );

    if (points.length < 2) {
      return;
    }

    const geometry =
      ribbonGeometry(
        state.city.seed,
        points,
        4.2,
        1.08,
      );

    if (!geometry) {
      return;
    }

    const mesh =
      new THREE.Mesh(
        geometry,
        new THREE.MeshStandardMaterial({
          color,
          emissive: color,
          emissiveIntensity: 0.32,
          roughness: 0.55,
          transparent:
            opacity < 1,
          opacity,
        }),
      );

    this.transportGroup.add(
      mesh,
    );
  }

  #stopObject(
    state,
    stop,
    color,
    name,
    selection,
    {
      ghost = false,
      selected = false,
      detail = null,
    } = {},
  ) {
    const group =
      new THREE.Group();

    const ground =
      terrainHeight(
        state.city.seed,
        stop.x,
        stop.y,
      );

    const base =
      new THREE.Mesh(
        new THREE.CylinderGeometry(
          ghost ? 16 : 13,
          ghost ? 16 : 13,
          ghost ? 2.2 : 3.2,
          16,
        ),
        new THREE.MeshStandardMaterial({
          color:
            ghost
              ? 0x242824
              : color,
          emissive:
            selected
              ? color
              : 0x000000,
          emissiveIntensity:
            selected
              ? 0.8
              : 0,
          transparent: ghost,
          opacity:
            ghost
              ? 0.58
              : 1,
          roughness: 0.72,
        }),
      );

    base.position.y =
      ground + 2;

    base.castShadow = true;
    group.add(base);

    if (ghost) {
      const ring =
        new THREE.Mesh(
          new THREE.TorusGeometry(
            18,
            1.8,
            8,
            24,
          ),
          new THREE.MeshBasicMaterial({
            color,
            transparent: true,
            opacity: 0.72,
          }),
        );

      ring.rotation.x =
        Math.PI / 2;

      ring.position.y =
        ground + 1.2;

      group.add(ring);
    }

    const label =
      textSprite(
        detail
          ? `${name}  ${detail}`
          : name,
        {
          accent:
            `#${new THREE.Color(color).getHexString()}`,
          width:
            detail ? 160 : 120,
          height: 26,
        },
      );

    label.position.set(
      0,
      ground + 32,
      0,
    );

    group.add(label);

    group.position.set(
      stop.x,
      0,
      stop.y,
    );

    this.#registerSelectable(
      group,
      selection,
    );

    this.transportGroup.add(
      group,
    );
  }

  #buildLine(
    state,
    lineKey,
    stops,
    names,
    color,
  ) {
    const line =
      state[lineKey];

    if (line.built) {
      const route =
        getBuiltRoute(
          lineKey,
          line.stopCount,
        );

      this.#buildTransitRibbon(
        state,
        route,
        color,
      );
    }

    for (
      let index = 0;
      index < line.stopCount;
      index += 1
    ) {
      if (
        lineKey === 'line2'
        && index === 0
      ) {
        continue;
      }

      this.#stopObject(
        state,
        stops[index],
        color,
        names[index],
        lineKey,
        {
          selected:
            this.selected
            === lineKey,
        },
      );
    }

    const maxStops =
      lineKey === 'line1'
        ? ECONOMY.maxLine1Stops
        : ECONOMY.maxLine2Stops;

    if (
      line.stopCount < maxStops
    ) {
      const future =
        getFutureSegmentRoute(
          lineKey,
          line.stopCount,
        );

      const geometry =
        lineGeometry(
          state.city.seed,
          linePointsFromMetrics(
            future,
          ),
          1.25,
        );

      const material =
        new THREE.LineDashedMaterial({
          color,
          transparent: true,
          opacity: 0.62,
          dashSize: 16,
          gapSize: 11,
        });

      const ghostLine =
        new THREE.Line(
          geometry,
          material,
        );

      ghostLine.computeLineDistances();

      this.transportGroup.add(
        ghostLine,
      );

      const selection =
        lineKey === 'line1'
          ? 'futureStop1'
          : 'futureStop2';

      this.#stopObject(
        state,
        stops[line.stopCount],
        color,
        names[line.stopCount],
        selection,
        {
          ghost: true,
          selected:
            this.selected
            === selection,
          detail:
            `$${getNextStopCost(state, lineKey)}`,
        },
      );
    }
  }

  #buildFutureLine2(state) {
    const future =
      getFutureSegmentRoute(
        'line2',
        1,
      );

    const geometry =
      lineGeometry(
        state.city.seed,
        linePointsFromMetrics(
          future,
        ),
        1.25,
      );

    const line =
      new THREE.Line(
        geometry,
        new THREE.LineDashedMaterial({
          color: LINE_2_COLOR,
          transparent: true,
          opacity: 0.62,
          dashSize: 16,
          gapSize: 11,
        }),
      );

    line.computeLineDistances();

    this.transportGroup.add(
      line,
    );

    this.#stopObject(
      state,
      WORLD.line2Stops[1],
      LINE_2_COLOR,
      STOP_NAMES.line2[1],
      'futureLine2',
      {
        ghost: true,
        selected:
          this.selected
          === 'futureLine2',
        detail:
          `$${ECONOMY.line2BuildCost}`,
      },
    );
  }

  #buildDepot(state) {
    if (
      !state.depot.built
      && !canBuildDepot(state)
    ) {
      return;
    }

    const spur =
      getDepotSpurRoute();

    if (state.depot.built) {
      this.#buildTransitRibbon(
        state,
        spur,
        0xb7b7ae,
        0.78,
      );
    } else {
      const geometry =
        lineGeometry(
          state.city.seed,
          linePointsFromMetrics(
            spur,
          ),
          1,
        );

      const line =
        new THREE.Line(
          geometry,
          new THREE.LineDashedMaterial({
            color: 0xb7b7ae,
            transparent: true,
            opacity: 0.52,
            dashSize: 12,
            gapSize: 9,
          }),
        );

      line.computeLineDistances();

      this.transportGroup.add(
        line,
      );
    }

    const ground =
      terrainHeight(
        state.city.seed,
        WORLD.depot.x,
        WORLD.depot.y,
      );

    const group =
      new THREE.Group();

    const base =
      new THREE.Mesh(
        new THREE.BoxGeometry(
          120,
          state.depot.built
            ? 24
            : 6,
          82,
        ),
        new THREE.MeshStandardMaterial({
          color:
            state.depot.built
              ? 0xa7aaa3
              : 0x343734,
          transparent:
            !state.depot.built,
          opacity:
            state.depot.built
              ? 1
              : 0.55,
          roughness: 0.9,
        }),
      );

    base.position.y =
      ground
      + (
        state.depot.built
          ? 12
          : 3
      );

    base.castShadow =
      state.depot.built;

    group.add(base);

    const selection =
      state.depot.built
        ? 'depot'
        : 'futureDepot';

    const label =
      textSprite(
        state.depot.built
          ? 'BUS DEPOT'
          : `BUS DEPOT  $${ECONOMY.depotBuildCost}`,
        {
          width: 150,
          height: 26,
        },
      );

    label.position.y =
      ground + 50;

    group.add(label);

    group.position.set(
      WORLD.depot.x,
      0,
      WORLD.depot.y,
    );

    this.#registerSelectable(
      group,
      selection,
    );

    this.transportGroup.add(
      group,
    );
  }

  #updateVehicles(state) {
    clearGroup(
      this.vehicleGroup,
    );

    const drawLineVehicles = (
      lineKey,
      color,
    ) => {
      const line =
        state[lineKey];

      if (!line.built) {
        return;
      }

      for (
        const vehicle
        of line.vehicles
      ) {
        const point =
          getVehiclePoint(
            lineKey,
            vehicle,
          );

        const ground =
          terrainHeight(
            state.city.seed,
            point.x,
            point.y,
          );

        const bus =
          new THREE.Mesh(
            new THREE.BoxGeometry(
              13,
              7,
              6.5,
            ),
            new THREE.MeshStandardMaterial({
              color,
              emissive: color,
              emissiveIntensity: 0.2,
              roughness: 0.58,
            }),
          );

        bus.position.set(
          point.x,
          ground + 5.5,
          point.y,
        );

        bus.rotation.y =
          -Math.atan2(
            point.ty ?? 0,
            point.tx ?? 1,
          );

        bus.castShadow = true;

        this.vehicleGroup.add(
          bus,
        );
      }
    };

    drawLineVehicles(
      'line1',
      LINE_1_COLOR,
    );

    drawLineVehicles(
      'line2',
      LINE_2_COLOR,
    );
  }

  render(
    state,
    deltaSeconds,
  ) {
    void deltaSeconds;

    this.#ensureTerrain(state);
    this.#focusInitial(state);
    this.#syncCity(state);
    this.#syncTransport(state);
    this.#updateVehicles(state);

    this.controls.update();

    this.renderer.render(
      this.scene,
      this.camera,
    );
  }
}
