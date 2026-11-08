//  DetectionProcessor.swift
//  The place to add your own processing step later.
//
//  The data flows like this:
//
//      FIRMSClient  ──►  FIRMSParser  ──►  [raw detections]  ──►  ProcessingPipeline  ──►  map
//      (download)         (CSV → model)     (cached + exported)    (YOUR CODE GOES HERE)
//
//  Right now the pipeline holds a single PassthroughProcessor, which returns the
//  detections unchanged. On purpose, nothing is clustered, merged, or filtered.
//
//  To add a step later (for example de-duplication or a classifier):
//    1. Write a new type that conforms to DetectionProcessor.
//    2. Add it to `ProcessingPipeline.current` below.
//  The map shows whatever the pipeline returns. CSV export always uses the raw data.

import Foundation

/// One step that takes detections in and returns detections out.
nonisolated protocol DetectionProcessor: Sendable {
    /// Short name, shown in the sidebar so you can see which steps are running.
    var name: String { get }
    func process(_ detections: [FireDetection]) async throws -> [FireDetection]
}

/// Returns its input unchanged. This is the only step for now.
nonisolated struct PassthroughProcessor: DetectionProcessor {
    let name = "Raw (no processing)"
    func process(_ detections: [FireDetection]) async throws -> [FireDetection] { detections }
}

/// Runs a list of processors in order, each one receiving the previous one's output.
nonisolated struct ProcessingPipeline: Sendable {
    var steps: [any DetectionProcessor]

    /// The pipeline the app uses. Add your future processors to this list.
    static let current = ProcessingPipeline(steps: [PassthroughProcessor()])

    @concurrent
    func run(_ detections: [FireDetection]) async throws -> [FireDetection] {
        var result = detections
        for step in steps { result = try await step.process(result) }
        return result
    }
}
