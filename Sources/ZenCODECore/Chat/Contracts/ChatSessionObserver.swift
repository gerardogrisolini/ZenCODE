//
//  ChatSessionObserver.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/11/26.
//

/// A presenter that observes a session's output whatever channel presents
/// it: the ``ChatSessionStateReducer`` that builds the session's snapshot.
///
/// An observer is attached to the controller with
/// ``ChatSessionController/addObserver(_:)`` and receives every call of the
/// presenter, in the same order, before the channel's presenter does. The
/// controller holds it strongly until ``ChatSessionController/removeObserver(_:)``
/// and identifies it by its object identity.
///
/// Like every ``ChatSessionPresenter`` it is `Sendable`. The controller calls
/// it from ``ChatSessionActor`` and awaits each call before the presenter's,
/// so an observer that blocks delays the channel's output.
///
/// An observer does not draw the task-graph or sub-agent overviews: those
/// publications are ordered by the presenting channel alone. The fan-out
/// still forwards ``ChatSessionPresenter/presentTaskGraphOverview(_:origin:publication:)``
/// and ``ChatSessionPresenter/presentSubAgentOverview(_:origin:publication:)``
/// to it, with the channel's reservation, which is harmless only while an
/// observer keeps the no-op defaults of the reservations.
public protocol ChatSessionObserver: AnyObject, ChatSessionPresenter {}
