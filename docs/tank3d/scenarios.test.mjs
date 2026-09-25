import assert from 'node:assert/strict';
import { SCENARIOS, buildTrack, sampleTank } from './scenarios.js';

const reverse = SCENARIOS.find(scene => scene.id === 'reverse');
const oldTrack = buildTrack(reverse, 'old');
const currentTrack = buildTrack(reverse, '2.3');
const oldLanding = sampleTank(reverse, oldTrack, 1.55);
const currentLanding = sampleTank(reverse, currentTrack, 1.55);

assert.ok(oldLanding.p[0] > currentLanding.p[0]);
assert.ok(sampleTank(reverse, oldTrack, 2.33).p[0] > oldLanding.p[0]);
assert.ok(sampleTank(reverse, currentTrack, 2.33).p[0] < currentLanding.p[0]);
assert.equal(Math.round(sampleTank(reverse, currentTrack, 1.525).speed * 100), 210);
assert.equal(Math.round(currentLanding.speed * 100), 210);
assert.match(currentLanding.state, /掉头跳/);

for (const scene of SCENARIOS) {
  for (const version of ['old', '2.0', '2.1', '2.3']) {
    const frames = buildTrack(scene, version, { difficulty: 4, strafe: true });
    assert.ok(frames.length > 1);
    assert.ok(sampleTank(scene, frames, scene.duration / 2).p.every(Number.isFinite));
  }
}
