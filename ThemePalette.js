// Status colours derived from the active Omarchy theme.
//
// The shell's Color singleton reads the theme's colors.toml but keeps only
// foreground, background, accent, muted and urgent; green and yellow are parsed
// over and discarded. So the panel reads the file itself for the traffic-light
// palette.
//
// It cannot take those values on trust. A theme's key named "green" is not
// reliably a green: hackerman sets red to #50f872, which is green, so a
// critical host would render as healthy. matte-black sets green to #FFC107 and
// yellow to #b91c1c, swapping healthy and warning. lumon, vantablack, solitude
// and white each give three mutually indistinguishable colours. On those
// themes, following the palette destroys the only thing the colour carries.
//
// So every theme triple is measured before it is used, and a theme that cannot
// carry the meaning keeps the built-in palette. Plain JS with no .pragma or
// .import so both Panel.qml and the test suite can load it.

// Minimum HSL saturation for a status colour. This is deliberately low: it
// exists only to reject palettes that are literally grey (vantablack at 0.00,
// white at 0.00, solitude at 0.06). Muted-but-real greens are common and
// legitimate - ethereal's sage #92a593 sits at 0.10, kanagawa at 0.17 - and
// the separation checks below are what actually protect legibility.
var MIN_SATURATION = 0.08;

// Minimum redmean distance between any two of the three roles, on the 0-765
// scale that metric produces. Below this a viewer cannot tell them apart at
// the size of a status dot (lumon's three blues, hackerman's green "red").
var MIN_SEPARATION = 60;

// Minimum distance from the panel background, so a status colour never sinks
// into the surface it is drawn on.
var MIN_BACKGROUND_SEPARATION = 40;

// Plausible hue ranges per role, in degrees. These reject semantic swaps that
// distance alone cannot see: matte-black's amber "green" and red "yellow",
// osaka-jade's green "yellow", last-horizon's purple "yellow".
var HUE_BANDS = {
  pass: [60, 200],   // olive-green (gruvbox sits at 70) through teal
  warn: [20, 70],    // orange through yellow
  fail: [335, 25],   // wraps zero: magenta-red through orange-red
};

function parseColorsToml(raw) {
  var values = {};
  var lines = String(raw || "").split("\n");
  for (var i = 0; i < lines.length; i++) {
    // Same shape the shell's own loader accepts: bare or quoted #rrggbb.
    var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/);
    if (match) values[match[1]] = match[2].toLowerCase();
  }
  return values;
}

function hexToRgb(hex) {
  var value = String(hex || "").replace(/^#/, "");
  if (!/^[0-9A-Fa-f]{6}$/.test(value)) return null;
  return {
    r: parseInt(value.slice(0, 2), 16),
    g: parseInt(value.slice(2, 4), 16),
    b: parseInt(value.slice(4, 6), 16),
  };
}

function saturationOf(rgb) {
  var r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255;
  var max = Math.max(r, g, b), min = Math.min(r, g, b);
  if (max === min) return 0;
  var l = (max + min) / 2;
  return l > 0.5 ? (max - min) / (2 - max - min) : (max - min) / (max + min);
}

function hueOf(rgb) {
  var r = rgb.r / 255, g = rgb.g / 255, b = rgb.b / 255;
  var max = Math.max(r, g, b), min = Math.min(r, g, b);
  if (max === min) return -1; // achromatic: no meaningful hue
  var d = max - min;
  var h;
  if (max === r) h = ((g - b) / d) % 6;
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  h *= 60;
  return h < 0 ? h + 360 : h;
}

function hueInBand(hue, band) {
  if (hue < 0) return false;
  var lo = band[0], hi = band[1];
  return lo <= hi ? (hue >= lo && hue <= hi) : (hue >= lo || hue <= hi);
}

// Redmean: a cheap approximation of perceptual distance that behaves far
// better than raw RGB euclidean around reds and greens, which is exactly where
// these judgements matter.
function colorDistance(a, b) {
  if (!a || !b) return 0;
  var rMean = (a.r + b.r) / 2;
  var dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b;
  return Math.sqrt(
    (((512 + rMean) * dr * dr) / 256) + 4 * dg * dg + (((767 - rMean) * db * db) / 256)
  );
}

/**
 * Resolve the traffic-light palette for a theme.
 *
 * Returns { pass, warn, fail, themed, reason }. `themed` is false when the
 * theme's own palette failed a check, and `reason` names which one, so the
 * decision is auditable rather than mysterious.
 */
function statusPalette(values, fallback, background) {
  var result = {
    pass: fallback.pass,
    warn: fallback.warn,
    fail: fallback.fail,
    themed: false,
    reason: "",
  };

  var source = values || {};
  // color2/3/1 are the ANSI names some themes use instead of the friendly ones.
  var candidate = {
    pass: source.green || source.color2 || source.bright_green || "",
    warn: source.yellow || source.color3 || source.bright_yellow || "",
    fail: source.red || source.color1 || source.bright_red || "",
  };

  var roles = ["pass", "warn", "fail"];
  var rgb = {};
  for (var i = 0; i < roles.length; i++) {
    var role = roles[i];
    var parsed = hexToRgb(candidate[role]);
    if (!parsed) {
      result.reason = "theme defines no " + role + " colour";
      return result;
    }
    if (saturationOf(parsed) < MIN_SATURATION) {
      result.reason = "theme " + role + " colour is too desaturated to read as a status";
      return result;
    }
    if (!hueInBand(hueOf(parsed), HUE_BANDS[role])) {
      result.reason = "theme " + role + " colour is outside the hue range that reads as "
        + role;
      return result;
    }
    rgb[role] = parsed;
  }

  var pairs = [["pass", "warn"], ["pass", "fail"], ["warn", "fail"]];
  for (var p = 0; p < pairs.length; p++) {
    if (colorDistance(rgb[pairs[p][0]], rgb[pairs[p][1]]) < MIN_SEPARATION) {
      result.reason = "theme " + pairs[p][0] + " and " + pairs[p][1]
        + " colours are too close to tell apart";
      return result;
    }
  }

  var backgroundRgb = hexToRgb(background);
  if (backgroundRgb) {
    for (var b = 0; b < roles.length; b++) {
      if (colorDistance(rgb[roles[b]], backgroundRgb) < MIN_BACKGROUND_SEPARATION) {
        result.reason = "theme " + roles[b] + " colour is too close to the background";
        return result;
      }
    }
  }

  result.pass = candidate.pass;
  result.warn = candidate.warn;
  result.fail = candidate.fail;
  result.themed = true;
  result.reason = "theme palette";
  return result;
}
