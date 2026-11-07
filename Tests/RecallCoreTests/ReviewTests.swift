import RecallCore
import Testing

@Test func playbackAdvancesOrLoopsAtTheTimelineBoundary() {
  #expect(PlaybackSchedule.nextIndex(current: 0, count: 3, looping: false) == 1)
  #expect(PlaybackSchedule.nextIndex(current: 2, count: 3, looping: false) == nil)
  #expect(PlaybackSchedule.nextIndex(current: 2, count: 3, looping: true) == 0)
  #expect(
    PlaybackSchedule.delayMilliseconds(for: .half)
      > PlaybackSchedule.delayMilliseconds(for: .one))
  #expect(
    PlaybackSchedule.delayMilliseconds(for: .one)
      > PlaybackSchedule.delayMilliseconds(for: .four))
}
