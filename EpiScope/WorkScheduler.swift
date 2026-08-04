import Foundation

// The app's single owner of expensive work.
//
// Everything costly EpiScope does — walking transcripts for the index, folding
// chart buckets, reconstructing rate-limit windows, backfilling the full-text
// index, running an analysis through the CLI — used to arrive its own way: its
// own timer, its own queue, its own hand-rolled coalescing and single-flight.
// Nothing could see the whole picture, so nothing could bound it.
//
// There are two entry points here and no third one:
//
//   * `register(Job)` — recurring work on a cadence (the tracker tick, the
//     monitor sample, the index heartbeat, the limit refresh).
//   * `run(Work)` — a one-shot piece of expensive work.
//
// A `Work` declares what it needs rather than how to get it:
//
//   * `group` — at most one Work per group runs at a time, because each group
//     is one serial queue. "scan" is every transcript walk, so they queue up
//     instead of thrashing the disk four abreast; "analysis" is the CLI runs.
//   * `coalesce` — while a Work with the same id waits, a newer submission
//     replaces it. This is what the search reconcile and the limit refresh
//     used to implement by hand, each differently.
//   * `priority` — `.interactive` for work somebody is watching (the chart of
//     a window that just opened), `.background` for everything else.
//   * `deferrable` — held during the launch window so a cold start belongs to
//     the visible table, not to the backfill.
//
// There is deliberately no cancellation. A `Cancellation` handle, a `cancel(id:)`
// and four checks at loop boundaries existed here for a while with no caller,
// so `isCancelled` was always false — and the file said otherwise, which is
// enough to make a reader reason about latencies that never happen. The one
// obvious client, standing the indexer down when its window closes, would have
// interrupted a deep scan halfway and paid for the same bytes again on the next
// open. Add it back when something actually needs it, not before.
final class WorkScheduler {
    static let shared = WorkScheduler()

    // MARK: - Types

    // Where a recurring job's body runs. `.main` is for jobs that touch
    // @MainActor state; `.queue` keeps a subsystem's own serial queue, which is
    // what serializes the job against that subsystem's other work.
    enum Target {
        case main
        case queue(DispatchQueue)
    }

    struct Job {
        let id: String
        let interval: TimeInterval
        let target: Target
        // Delay before the first run. Several jobs want to skip the launch
        // stampede (insights waits a minute for the indexer to publish).
        let initialDelay: TimeInterval
        let body: () -> Void

        init(id: String, interval: TimeInterval, target: Target,
             initialDelay: TimeInterval = 0, body: @escaping () -> Void) {
            self.id = id
            self.interval = interval
            self.target = target
            self.initialDelay = initialDelay
            self.body = body
        }
    }

    enum Priority {
        case interactive   // somebody is watching the result
        case background    // nobody is

        var qos: DispatchQoS { self == .interactive ? .userInitiated : .utility }
    }

    struct Work {
        let id: String
        var group: String = Group.scan
        var priority: Priority = .background
        // Latest submission wins while an earlier one is still queued.
        var coalesce: Bool = true
        // Held until the launch window closes (see admitDeferred).
        var deferrable: Bool = true

        init(id: String, group: String = Group.scan, priority: Priority = .background,
             coalesce: Bool = true, deferrable: Bool = true) {
            self.id = id
            self.group = group
            self.priority = priority
            self.coalesce = coalesce
            self.deferrable = deferrable
        }
    }

    // The exclusion groups in use. One serial queue each, so membership is the
    // whole contract: same group ⇒ never at the same time.
    enum Group {
        static let scan = "scan"          // transcript walks
        static let index = "index"        // session-index passes (feed the table)
        static let analysis = "analysis"  // CLI runs and their packet prep
    }

    // MARK: - Storage

    // Per-job bookkeeping. Only ever touched on `queue`.
    private struct JobState {
        var lastRun: Date
        var inFlight = false
        var enabled = true
    }

    private struct Pending {
        let work: Work
        let body: () -> Void
    }

    // The heartbeat is 1 s and every cadence is a multiple of it. The epsilon
    // keeps a 1 s job firing on every tick rather than every other one when the
    // timer lands a hair early; the leeway lets the OS coalesce our wakeup with
    // whatever else it is already doing.
    private static let heartbeat: TimeInterval = 1.0
    private static let epsilon: TimeInterval = 0.25

    private let queue = DispatchQueue(label: "episcope.scheduler", qos: .utility)
    private var jobs: [String: Job] = [:]
    private var jobState: [String: JobState] = [:]
    private var timer: DispatchSourceTimer?

    // One serial queue per group — this is the mechanism, not an optimisation:
    // "at most one transcript walk at a time" is expressed by them sharing a
    // queue, so no caller can opt out of it by accident.
    private var groupQueues: [String: DispatchQueue] = [:]
    // Queued-but-not-started work, keyed by Work.id for coalescing.
    private var pending: [String: Pending] = [:]
    // Ids whose body is executing right now. Coalescing only ever saw work that
    // had not started yet, so a resubmission during a long run queued a second
    // full pass behind it — four clicks on the Limits mode meant four
    // independent walks of the whole corpus, and nothing cancels them.
    private var running: Set<String> = []
    // Groups currently held by a lease (a running child process), and whoever
    // is queued for the group after it.
    private var leased: Set<String> = []
    private var leaseWaiters: [String: [(Lease) -> Void]] = [:]

    // Launch admission. Deferrable work waits for the index's first pass, with
    // a floor (a warm start finds nothing to do and would admit immediately)
    // and a backstop (a huge history must not hold it forever).
    private var admitted = false
    private var admissionScheduled = false
    private static let launchSettle: TimeInterval = 5
    private static let admissionBackstop: TimeInterval = 30
    private let startedAt = Date()

    // MARK: - Recurring jobs

    func register(_ job: Job) {
        queue.async {
            self.jobs[job.id] = job
            // A first run lands `interval` after registration, or after
            // `initialDelay` when the job asked for a later start.
            let backdate = job.interval - job.initialDelay
            self.jobState[job.id] = JobState(lastRun: Date().addingTimeInterval(-backdate))
            self.startTimerIfNeeded()
        }
    }

    // Pausing beats gating: a disabled job costs nothing per tick, which is the
    // point of the indexer standing down while its window is closed.
    func setEnabled(_ enabled: Bool, id: String) {
        queue.async {
            self.jobState[id]?.enabled = enabled
            // Re-enabling shouldn't hold the job back for a whole interval —
            // callers that resume usually want fresh data now.
            if enabled { self.jobState[id]?.lastRun = .distantPast }
        }
    }

    // MARK: - One-shot work

    func run(_ work: Work, _ body: @escaping () -> Void) {
        queue.async {
            if work.coalesce, self.pending[work.id] != nil {
                // Same work already waiting — the newer body wins.
                self.pending[work.id] = Pending(work: work, body: body)
                return
            }
            self.pending[work.id] = Pending(work: work, body: body)
            guard !work.deferrable || self.admitted else { return }
            self.dispatch(id: work.id)
        }
    }

    // A lease keeps a group busy without occupying its queue. An analysis is
    // minutes of a child process: parking it on the serial queue would hold a
    // thread the whole time to do nothing but wait. It takes a lease instead —
    // later Work in that group queues behind it, work in every other group is
    // untouched — and releases it when the process exits.
    final class Lease {
        private let onRelease: () -> Void
        private let lock = NSLock()
        private var released = false
        init(_ onRelease: @escaping () -> Void) { self.onRelease = onRelease }
        func release() {
            lock.lock()
            let first = !released
            released = true
            lock.unlock()
            if first { onRelease() }
        }
        deinit { release() }
    }

    // `granted` runs on the scheduler's queue once the group is free.
    func lease(group: String, _ granted: @escaping (Lease) -> Void) {
        queue.async {
            if self.leased.contains(group) {
                self.leaseWaiters[group, default: []].append(granted)
            } else {
                self.grantLease(group: group, to: granted)
            }
        }
    }

    private func grantLease(group: String, to granted: @escaping (Lease) -> Void) {
        leased.insert(group)
        granted(Lease { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.leased.remove(group)
                // Hand the group to the next lease if one is waiting, otherwise
                // let the Work that piled up behind it through.
                if var waiting = self.leaseWaiters[group], !waiting.isEmpty {
                    let next = waiting.removeFirst()
                    self.leaseWaiters[group] = waiting.isEmpty ? nil : waiting
                    self.grantLease(group: group, to: next)
                    return
                }
                for (id, item) in self.pending where item.work.group == group {
                    self.dispatch(id: id)
                }
            }
        })
    }

    // Called once the session index has finished its first pass.
    func admitDeferred() {
        queue.async {
            guard !self.admitted else { return }
            let elapsed = Date().timeIntervalSince(self.startedAt)
            guard elapsed >= Self.launchSettle else {
                guard !self.admissionScheduled else { return }
                self.admissionScheduled = true
                self.queue.asyncAfter(deadline: .now() + (Self.launchSettle - elapsed)) {
                    self.admissionScheduled = false
                    self.admitDeferred()
                }
                return
            }
            self.admitted = true
            for id in self.pending.keys { self.dispatch(id: id) }
        }
    }

    // MARK: - Dispatch

    private func groupQueue(_ name: String) -> DispatchQueue {
        if let q = groupQueues[name] { return q }
        let q = DispatchQueue(label: "episcope.\(name)", qos: .utility)
        groupQueues[name] = q
        return q
    }

    private func dispatch(id: String) {
        // A leased group is busy even though its queue is idle — that is the
        // point of the lease. Leave the work pending; releasing the lease
        // dispatches it.
        guard let peek = pending[id], !leased.contains(peek.work.group) else { return }
        // Already in flight under this id: leave the submission pending, so it
        // runs once afterwards instead of stacking another pass behind it.
        guard !running.contains(id) else { return }
        guard let item = pending.removeValue(forKey: id) else { return }
        running.insert(id)
        groupQueue(item.work.group).async(qos: item.work.priority.qos) {
            item.body()
            self.queue.async {
                self.running.remove(id)
                // Whatever arrived while this was running is still pending.
                self.dispatch(id: id)
            }
        }
    }

    // MARK: - Heartbeat

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Self.heartbeat,
                   repeating: Self.heartbeat,
                   leeway: .milliseconds(150))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        queue.asyncAfter(deadline: .now() + Self.admissionBackstop) { [weak self] in
            self?.admitDeferred()
        }
    }

    private func tick() {
        let now = Date()
        for (id, job) in jobs {
            guard let s = jobState[id], s.enabled, !s.inFlight,
                  now.timeIntervalSince(s.lastRun) >= job.interval - Self.epsilon
            else { continue }
            fireJob(id: id, now: now)
        }
    }

    private func fireJob(id: String, now: Date) {
        guard let job = jobs[id], var s = jobState[id], s.enabled, !s.inFlight else { return }
        s.inFlight = true
        s.lastRun = now
        jobState[id] = s

        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            self.queue.async { self.jobState[id]?.inFlight = false }
        }
        switch job.target {
        case .main:
            DispatchQueue.main.async { job.body(); finish() }
        case .queue(let q):
            q.async { job.body(); finish() }
        }
    }
}
