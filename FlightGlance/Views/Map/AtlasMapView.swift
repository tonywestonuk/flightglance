import SwiftUI

/// Camera state and commands for an interactive map, shared between the map view and the
/// dashboard's map buttons.
@MainActor
@Observable
final class MapController {
    var camera = GeoCamera(latitude: 20, longitude: 0, radius: 150)
    var style: MapStyle = .globe {
        didSet { if oldValue != style { camera = camera.clamped(style: style, size: viewSize) } }
    }
    /// When true the camera keeps the aircraft centred as new fixes arrive. Any manual pan
    /// turns it off; the "centre on aircraft" button turns it back on.
    var isFollowing = true
    private(set) var viewSize: CGSize = .zero
    /// Screen areas covered by floating chrome (top bar, buttons, safe areas). Content is
    /// framed and centred within what remains.
    var chromeInsets = EdgeInsets(top: 72, leading: 0, bottom: 12, trailing: 64)
    @ObservationIgnored private var hasInitialFrame = false

    init(style: MapStyle = .globe) {
        self.style = style
    }

    /// Padding used when fitting content to the view.
    var fitPadding: EdgeInsets {
        EdgeInsets(top: chromeInsets.top + 20, leading: chromeInsets.leading + 28,
                   bottom: chromeInsets.bottom + 16, trailing: chromeInsets.trailing + 12)
    }

    /// Offset of the visual centre of the unobscured map from the view's geometric centre.
    /// Only the vertical chrome is considered: the narrow button column shouldn't nudge the
    /// aircraft sideways.
    var focusOffset: CGSize {
        CGSize(width: 0, height: (chromeInsets.top - chromeInsets.bottom) / 2)
    }

    var focusPoint: CGPoint {
        CGPoint(x: viewSize.width / 2 + focusOffset.width, y: viewSize.height / 2 + focusOffset.height)
    }

    func updateViewSize(_ size: CGSize, initialFrame: () -> GeoCamera?) {
        guard size.width > 1, size.height > 1 else { return }
        viewSize = size
        if !hasInitialFrame, let camera = initialFrame() {
            self.camera = camera
            hasInitialFrame = true
        } else {
            camera = camera.clamped(style: style, size: size)
        }
    }

    func pan(by delta: CGSize) {
        isFollowing = false
        camera = camera.panned(by: delta, style: style, size: viewSize)
    }

    /// Continues a drag with deceleration, using SwiftUI's predicted end translation.
    func fling(by delta: CGSize) {
        guard hypot(delta.width, delta.height) > 30 else { return }
        let target = camera.panned(by: delta, style: style, size: viewSize)
        withAnimation(.easeOut(duration: 0.6)) { camera = target }
    }

    /// Zooms around `anchor`. While following, zoom around the aircraft so it stays put.
    func zoom(by factor: CGFloat, anchor: CGPoint?, animated: Bool = false) {
        let pivot = isFollowing ? focusPoint : (anchor ?? focusPoint)
        let next = camera.zoomed(by: factor, anchor: pivot, style: style, size: viewSize)
        if animated {
            withAnimation(.smooth(duration: 0.35)) { camera = next }
        } else {
            camera = next
        }
    }

    /// Centres on the aircraft and resumes following.
    func center(on point: GeoPoint, animated: Bool = true) {
        isFollowing = true
        move(to: point, animation: animated ? .smooth(duration: 0.6) : nil)
    }

    /// Keeps the aircraft centred if following.
    ///
    /// Deliberately *not* animated: an airliner moves far less than a point per second at
    /// any zoom level, so there is nothing to see, and animating after every 1 Hz fix would
    /// keep the globe re-rendering at the display's full frame rate (a big battery and heat
    /// cost on a long flight). One redraw per fix is enough.
    func follow(_ point: GeoPoint?) {
        guard isFollowing, let point, hasInitialFrame else { return }
        // Leave the camera alone until the aircraft has drifted a couple of points from the
        // centre. At cruise that is every few seconds when zoomed right in and every few
        // minutes when viewing the whole globe, so the base map is rarely redrawn.
        if let current = camera.screenPoint(of: point, style: style, size: viewSize),
           hypot(current.x - focusPoint.x, current.y - focusPoint.y) < 2 {
            return
        }
        move(to: point, animation: nil)
    }

    func fit(_ points: [GeoPoint], animated: Bool = true) {
        guard viewSize.width > 1,
              var target = GeoCamera.framing(points, style: style, size: viewSize, padding: fitPadding) else { return }
        isFollowing = false
        target.longitude = GeoMath.unwrap(target.longitude, near: camera.longitude)
        if animated {
            withAnimation(.smooth(duration: 0.7)) { camera = target }
        } else {
            camera = target
        }
    }

    private func move(to point: GeoPoint, animation: Animation?) {
        let target = camera.centered(on: point, focusOffset: focusOffset, style: style, size: viewSize)
        if let animation {
            withAnimation(animation) { camera = target }
        } else {
            camera = target
        }
    }
}

/// The interactive offline map: drag to pan (flat) or rotate (globe), pinch to zoom around
/// your fingers, double-tap to zoom in, and fling with deceleration.
struct AtlasMapView: View {
    let atlas: WorldAtlas
    let overlay: MapOverlay
    let controller: MapController
    /// Initial framing, evaluated once the view knows its size.
    var initialFrame: (CGSize) -> GeoCamera?
    var accessibilitySummary: String = ""

    @State private var lastDrag: CGSize = .zero
    @State private var lastMagnification: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            AtlasCanvas(atlas: atlas, overlay: overlay, camera: controller.camera, style: controller.style)
                .contentShape(Rectangle())
                .gesture(panAndZoom)
                .simultaneousGesture(doubleTap)
                .onAppear {
                    controller.updateViewSize(geometry.size) { initialFrame(geometry.size) }
                }
                .onChange(of: geometry.size) { _, size in
                    controller.updateViewSize(size) { initialFrame(size) }
                }
        }
        .accessibilityElement()
        .accessibilityLabel(controller.style == .globe ? "Globe" : "Map")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Pinch or double-tap to zoom, drag to move.")
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityZoomAction { action in
            controller.zoom(by: action.direction == .zoomIn ? 2 : 0.5, anchor: nil, animated: true)
        }
    }

    private var panAndZoom: some Gesture {
        let drag = DragGesture(minimumDistance: 1)
            .onChanged { value in
                let delta = CGSize(width: value.translation.width - lastDrag.width,
                                   height: value.translation.height - lastDrag.height)
                lastDrag = value.translation
                controller.pan(by: delta)
            }
            .onEnded { value in
                lastDrag = .zero
                controller.fling(by: CGSize(
                    width: (value.predictedEndTranslation.width - value.translation.width) * 0.6,
                    height: (value.predictedEndTranslation.height - value.translation.height) * 0.6))
            }
        let magnify = MagnifyGesture()
            .onChanged { value in
                // Apply incremental factors so pinch and pan compose without fighting.
                let factor = value.magnification / lastMagnification
                lastMagnification = value.magnification
                controller.zoom(by: factor, anchor: value.startLocation)
            }
            .onEnded { _ in lastMagnification = 1 }
        return drag.simultaneously(with: magnify)
    }

    private var doubleTap: some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            controller.zoom(by: 2, anchor: value.location, animated: true)
        }
    }
}

/// The drawing surface. Conforms to `Animatable` through its camera, so camera changes made
/// inside `withAnimation` (recentre, fit route, fling) are interpolated frame by frame.
struct AtlasCanvas: View, Animatable {
    let atlas: WorldAtlas
    let overlay: MapOverlay
    var camera: GeoCamera
    var style: MapStyle = .globe
    var showsCityLabels = true

    nonisolated var animatableData: GeoCamera.AnimatableData {
        get { camera.animatableData }
        set { camera.animatableData = newValue }
    }

    var body: some View {
        ZStack {
            AtlasBaseLayer(atlas: atlas, camera: camera, style: style, markers: overlay.markers,
                           showsCityLabels: showsCityLabels)
                .equatable()
            Canvas { context, size in
                AtlasCanvas.render(.flight, atlas: atlas, overlay: overlay, camera: camera, style: style,
                                   showsCityLabels: false, in: &context, size: size)
            }
        }
        // Map labels follow Dynamic Type but are capped so they can't swamp the map.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
    }

    static func render(_ layer: MapLayer, atlas: WorldAtlas, overlay: MapOverlay, camera: GeoCamera, style: MapStyle,
                       showsCityLabels: Bool, in context: inout GraphicsContext, size: CGSize) {
        switch style {
        case .globe:
            GlobeRenderer(atlas: atlas, showsCityLabels: showsCityLabels)
                .draw(in: &context, size: size, camera: camera, overlay: overlay, layer: layer)
        case .flat:
            AtlasRenderer(atlas: atlas, showsCityLabels: showsCityLabels)
                .draw(in: &context, size: size, camera: camera.flatCamera, overlay: overlay, layer: layer)
        }
    }
}

/// The expensive part of the map (land, coasts, shading, labels). `Equatable` so SwiftUI
/// skips re-rendering it entirely unless the camera, style or airports actually change —
/// new GPS fixes only redraw the light flight layer on top.
private struct AtlasBaseLayer: View, Equatable {
    let atlas: WorldAtlas
    let camera: GeoCamera
    let style: MapStyle
    let markers: [MapOverlay.AirportMarker]
    let showsCityLabels: Bool

    nonisolated static func == (lhs: AtlasBaseLayer, rhs: AtlasBaseLayer) -> Bool {
        lhs.atlas === rhs.atlas && lhs.camera == rhs.camera && lhs.style == rhs.style
            && lhs.markers == rhs.markers && lhs.showsCityLabels == rhs.showsCityLabels
    }

    var body: some View {
        Canvas { context, size in
            var overlay = MapOverlay()
            overlay.markers = markers
            AtlasCanvas.render(.base, atlas: atlas, overlay: overlay, camera: camera, style: style,
                               showsCityLabels: showsCityLabels, in: &context, size: size)
        }
    }
}

/// Non-interactive map used for the route preview on the setup screen.
struct StaticAtlasMap: View {
    let atlas: WorldAtlas
    let overlay: MapOverlay
    var style: MapStyle = .globe
    var padding = EdgeInsets(top: 24, leading: 24, bottom: 24, trailing: 24)

    var body: some View {
        GeometryReader { geometry in
            AtlasCanvas(atlas: atlas, overlay: overlay, camera: camera(for: geometry.size), style: style)
        }
    }

    private func camera(for size: CGSize) -> GeoCamera {
        GeoCamera.framing(overlay.framingPoints, style: style, size: size, padding: padding)
            ?? GeoCamera(latitude: 20, longitude: 0, radius: 0).clamped(style: style, size: size)
    }
}
