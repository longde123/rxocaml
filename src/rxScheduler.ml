(* Internal module. (see Rx.Scheduler)
 *
 * Implementation based on:
 * https://github.com/Netflix/RxJava/blob/master/rxjava-core/src/main/java/rx/Scheduler.java
 *)

module type Base = sig
  type t

  val now : unit -> float

  val schedule_absolute :
    ?due_time:float -> (unit -> RxCore.subscription) ->
    RxCore.subscription

end

module type S = sig
  include Base

  val schedule_relative :
    float -> (unit -> RxCore.subscription) ->
    RxCore.subscription

  val schedule_recursive :
    ((unit -> RxCore.subscription) -> RxCore.subscription) ->
    RxCore.subscription

  val schedule_periodically :
    ?initial_delay:float -> float -> (unit -> RxCore.subscription) ->
    RxCore.subscription

end

module MakeScheduler(BaseScheduler : Base) = struct
  include BaseScheduler

  let schedule_relative delay action =
    let due_time = BaseScheduler.now () +. delay in
    BaseScheduler.schedule_absolute ~due_time action

  let schedule_recursive cont =
    let open RxSubscription in
    let (child_subscription, child_state) =
      MultipleAssignment.create empty in
    let (parent_subscription, parent_state) =
      Composite.create [child_subscription] in
    let rec schedule_k k =
      let k_subscription =
        if Composite.is_unsubscribed parent_state then empty
        else BaseScheduler.schedule_absolute
          (fun () -> k (fun () -> schedule_k k))
      in
      MultipleAssignment.set child_state k_subscription;
      child_subscription in
    let scheduled_subscription =
      BaseScheduler.schedule_absolute (fun () -> schedule_k cont)
    in
    Composite.add parent_state scheduled_subscription;
    parent_subscription

  let schedule_periodically ?initial_delay period action =
    let completed = RxAtomicData.create false in
    let rec loop () =
      if not (RxAtomicData.unsafe_get completed) then begin
        let started_at = BaseScheduler.now () in
        let unsubscribe1 = action () in
        let time_taken = (now ()) -. started_at in
        let delay = period -. time_taken in
        let unsubscribe2 = schedule_relative delay loop in
        RxSubscription.create (
          fun () ->
            unsubscribe1 ();
            unsubscribe2 ();
        )
      end else RxSubscription.empty
    in
    let delay = BatOption.default 0. initial_delay in
    let unsubscribe = schedule_relative delay loop in
    RxSubscription.create (
      fun () ->
        RxAtomicData.set true completed;
        unsubscribe ()
    )

end

let create_sleeping_action action exec_time now =
  (fun () ->
    if exec_time > now () then begin
      let delay = exec_time -. (now ()) in
      if delay > 0.0 then Thread.delay delay;
    end;
    action ())

module DiscardableAction = struct
  type t = {
    ready: bool;
    unsubscribe: RxCore.subscription;
  }

  let create_state () =
    let state = RxAtomicData.create {
      ready = true;
      unsubscribe = RxSubscription.empty;
    } in
    RxAtomicData.update
      (fun s ->
        { s with
          unsubscribe =
            (fun () ->
              RxAtomicData.update (fun s' -> { s' with ready = false }) state)
        }
      ) state;
    state

  let was_ready state =
    let old_state =
      RxAtomicData.update_if
        (fun s -> s.ready = true)
        (fun s -> { s with ready = false })
        state
    in
    old_state.ready

  let create action =
    let state = create_state () in
    ((fun () ->
      if was_ready state then begin
        let unsubscribe = action () in
        RxAtomicData.update
          (fun s -> { s with unsubscribe = unsubscribe }) state
      end), (RxAtomicData.unsafe_get state).unsubscribe)

  let create_lwt action =
    let state = create_state () in
    let was_ready_thread = Lwt.wrap (fun () -> was_ready state) in
    ((Lwt.bind was_ready_thread
     (fun was_ready ->
       if was_ready then begin
         Lwt.bind action
           (fun unsubscribe ->
             RxAtomicData.update
               (fun s -> { s with unsubscribe = unsubscribe }) state;
             Lwt.return_unit
           )
       end else Lwt.return_unit
     )), (RxAtomicData.unsafe_get state).unsubscribe)

end

module TimedAction = struct
  type t = {
    discardable_action : unit -> unit;
    exec_time : float;
    count : int;
  }

  let compare ta1 ta2 =
    let result = compare ta1.exec_time ta2.exec_time in
    if result = 0 then
      compare ta1.count ta2.count
    else result

end

module TimedActionPriorityQueue = BatHeap.Make(TimedAction)

module CurrentThreadBase = struct
  type t = {
    queue_table: (int, TimedActionPriorityQueue.t option) Hashtbl.t;
    counter: int;
  }

  let current_state = RxAtomicData.create {
    queue_table = Hashtbl.create 16;
    counter = 0;
  }

  let now () = Unix.gettimeofday ()

  let get_queue state =
    let tid = Utils.current_thread_id () in
    let queue_table = state.queue_table in
    try
      Hashtbl.find queue_table tid
    with Not_found ->
      let queue = None in
      Hashtbl.add queue_table tid queue;
      queue

  let set_queue queue state =
    let tid = Utils.current_thread_id () in
    Hashtbl.replace state.queue_table tid queue

  let enqueue action exec_time =
    let exec =
      RxAtomicData.synchronize
        (fun state ->
          let queue_option = get_queue state in
          let (exec, queue) =
            match queue_option with
              None ->
                (true, TimedActionPriorityQueue.empty)
            | Some q ->
                (false, q) in
          let queue' = TimedActionPriorityQueue.insert queue {
            TimedAction.discardable_action = action;
            exec_time;
            count = state.counter;
          } in
          RxAtomicData.unsafe_set
            { state with counter = succ state.counter}
            current_state;
          set_queue (Some queue') state;
          exec) current_state in
    let reset_queue () =
      RxAtomicData.synchronize
        (fun state -> set_queue None state)
        current_state in
    if exec then begin
      try
        while true do
          let action =
            RxAtomicData.synchronize
              (fun state ->
                let queue = BatOption.get (get_queue state) in
                let result = TimedActionPriorityQueue.find_min queue in
                let queue' = TimedActionPriorityQueue.del_min queue in
                set_queue (Some queue') state;
                result.TimedAction.discardable_action) current_state in
          action ()
        done
      with
      | Invalid_argument "find_min" -> reset_queue ()
      | e -> reset_queue (); raise e
    end

  let schedule_absolute ?due_time action =
    let (exec_time, action') =
      match due_time with
      | None -> (now (), action)
      | Some dt -> (dt, create_sleeping_action action dt now) in
    let (discardable_action, unsubscribe) = DiscardableAction.create action' in
    enqueue discardable_action exec_time;
    unsubscribe

end

module CurrentThread = MakeScheduler(CurrentThreadBase)

module ImmediateBase = struct
  (* Implementation based on:
   * /usr/local/src/RxJava/rxjava-core/src/main/java/rx/schedulers/ImmediateScheduler.java
   *)
  type t = unit

  let now () = Unix.gettimeofday ()

  let schedule_absolute ?due_time action =
    let (exec_time, action') =
      match due_time with
      | None -> (now (), action)
      | Some dt -> (dt, create_sleeping_action action dt now) in
    action' ()

end

module Immediate = MakeScheduler(ImmediateBase)

module NewThreadBase = struct
  type t = unit

  let now () = Unix.gettimeofday ()

  let schedule_absolute ?due_time action =
    let (exec_time, action') =
      match due_time with
      | None -> (now (), action)
      | Some dt -> (dt, create_sleeping_action action dt now) in
    let (discardable_action, unsubscribe) = DiscardableAction.create action' in
    let _ = Thread.create discardable_action () in
    unsubscribe

end

module NewThread = MakeScheduler(NewThreadBase)

module LwtBase = struct
  type t = unit

  let now () = Unix.gettimeofday ()

  let create_sleeping_action action exec_time =
    let delay_action =
      if exec_time > now () then begin
        let delay = exec_time -. (now ()) in
        if delay > 0.0 then Lwt_unix.sleep delay else Lwt.return_unit
      end else Lwt.return_unit in
    Lwt.bind delay_action (fun () -> Lwt.wrap action)

  let schedule_absolute ?due_time action =
    let (exec_time, action') =
      match due_time with
      | None -> (now (), Lwt.wrap action)
      | Some dt -> (dt, create_sleeping_action action dt) in
    let (discardable_action, unsubscribe) =
      DiscardableAction.create_lwt action' in
    let (waiter, wakener) = Lwt.task () in
    let lwt_unsubscribe = RxSubscription.from_task waiter in
    let _ = Lwt.bind waiter (fun () -> discardable_action) in
    let () = Lwt.wakeup_later wakener () in
    (fun () ->
      lwt_unsubscribe ();
      unsubscribe ();
    )

end

module Lwt = MakeScheduler(LwtBase)

module TestBase = struct
  (* Implementation based on:
   * /usr/local/src/RxJava/rxjava-core/src/main/java/rx/schedulers/TestScheduler.java
   *)

  type t = {
    mutable queue: TimedActionPriorityQueue.t;
    mutable time: float;
  }

  let current_state = {
    queue = TimedActionPriorityQueue.empty;
    time = 0.0;
  }

  let now () = current_state.time

  let schedule_absolute ?due_time action =
    let exec_time =
      match due_time with
      | None -> now ()
      | Some dt -> dt in
    let (discardable_action, unsubscribe) =
      DiscardableAction.create action in
    let queue = TimedActionPriorityQueue.insert current_state.queue {
      TimedAction.discardable_action;
      exec_time;
      count = 0;
    } in
    current_state.queue <- queue;
    unsubscribe

  let trigger_actions target_time =
    let rec loop () =
      try
        let timed_action =
          TimedActionPriorityQueue.find_min current_state.queue in
        if timed_action.TimedAction.exec_time <= target_time then begin
          let queue =
            TimedActionPriorityQueue.del_min current_state.queue in
          current_state.time <- timed_action.TimedAction.exec_time;
          current_state.queue <- queue;
          timed_action.TimedAction.discardable_action ();
          loop ()
        end
      with Invalid_argument "find_min" -> ()
    in
    loop ()

  let trigger_actions_until_now () =
    trigger_actions current_state.time

  let advance_time_to delay =
    current_state.time <- delay;
    trigger_actions delay

  let advance_time_by delay =
    let target_time = current_state.time +. delay in
    trigger_actions target_time

end

module Test = struct
  include MakeScheduler(TestBase)

  let now = TestBase.now

  let trigger_actions = TestBase.trigger_actions

  let trigger_actions_until_now = TestBase.trigger_actions_until_now

  let advance_time_to = TestBase.advance_time_to

  let advance_time_by = TestBase.advance_time_by

end

