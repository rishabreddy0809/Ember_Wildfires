//  Bodies.swift
//  Everything the 3D Earth is made of: textures, materials and their small GPU shaders
//  (SceneKit shader modifiers, which compile to Metal), the camera, and the paper labels.

import SwiftUI
import SceneKit
import AppKit

/// Textures and materials for the globe. All imagery is NASA: Blue Marble and Black Marble
/// via GIBS, VIIRS true colour for the cloud layer, and the SVS Deep Star Map for the sky.
@MainActor
enum Bodies {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, _ ext: String = "jpg") -> NSImage? {
        if let i = cache[name] { return i }
        let i = Bundle.main.url(forResource: name, withExtension: ext).flatMap(NSImage.init(contentsOf:))
        cache[name] = i
        return i
    }

    /// Direction toward the Sun in view space. The camera never rotates, so this is also world space.
    static let sunDirection = SCNVector3(-0.74, 0.28, 0.61)

    static func sunLight(intensity: CGFloat = 3000) -> SCNNode {
        let n = SCNNode()
        let l = SCNLight()
        l.type = .directional
        l.intensity = intensity
        l.color = NSColor(calibratedRed: 1.0, green: 0.975, blue: 0.93, alpha: 1)
        n.light = l
        n.position = SCNVector3(sunDirection.x * 10, sunDirection.y * 10, sunDirection.z * 10)
        n.look(at: SCNVector3(0, 0, 0))
        return n
    }

    /// Rings that spread across the surface from a point, like sonar. `pingDir` is the
    /// point as a unit vector in the sphere's own frame, rebuilt here from the UV.
    private static func ping(reach: String, width: String, color: String) -> String {
        """
        float2 puv = _surface.diffuseTexcoord;
        float plam = (puv.x - 0.5) * 6.2831853;
        float pphi = (0.5 - puv.y) * 3.14159265;
        float3 pp = float3(cos(pphi) * sin(plam), sin(pphi), cos(pphi) * cos(plam));
        float pang = acos(clamp(dot(pp, normalize(pingDir)), -1.0, 1.0));
        float pt1 = fract(scn_frame.time / 3.4);
        float pt2 = fract(scn_frame.time / 3.4 + 0.5);
        float ring = exp(-pow((pang - pt1 * \(reach)) / \(width), 2.0)) * (1.0 - pt1)
                   + exp(-pow((pang - pt2 * \(reach)) / \(width), 2.0)) * (1.0 - pt2);
        _surface.emission.rgb += \(color) * ring * pingOn * 1.8;
        """
    }

    private static let whitePixel: NSImage = {
        NSImage(size: NSSize(width: 2, height: 2), flipped: false) { r in NSColor.white.setFill(); r.fill(); return true }
    }()

    static func earthMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = image("earth_day")
        m.diffuse.mipFilter = .linear
        m.diffuse.maxAnisotropy = 8
        m.normal.contents = image("earth_normal")
        m.normal.intensity = 0.7
        m.roughness.contents = image("earth_rough")
        m.metalness.contents = 0.0
        m.diffuse.intensity = 0.72
        m.emission.contents = image("earth_night")
        m.emission.mipFilter = .linear
        // City lights only on the night side; warm scattering along the terminator.
        m.shaderModifiers = [.surface: """
        #pragma arguments
        float3 sunDir;
        float3 pingDir;
        float pingOn;
        #pragma body
        float ndl = dot(normalize(_surface.normal), normalize(sunDir));
        float night = 1.0 - smoothstep(-0.18, 0.06, ndl);
        _surface.emission.rgb = _surface.emission.rgb * night * 2.6;
        float dusk = exp(-(ndl * ndl) / 0.02);
        _surface.diffuse.rgb = mix(_surface.diffuse.rgb, _surface.diffuse.rgb * float3(1.35, 0.72, 0.42), dusk * 0.55);

        """ + ping(reach: "1.1", width: "0.012", color: "float3(1.0, 0.75, 0.45)")]
        m.setValue(NSValue(scnVector3: sunDirection), forKey: "sunDir")
        m.setValue(NSValue(scnVector3: SCNVector3(0, 0, 1)), forKey: "pingDir")
        m.setValue(NSNumber(value: Float(0)), forKey: "pingOn")
        return m
    }

    static func cloudMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .lambert
        m.diffuse.contents = image("earth_clouds", "png")
        m.diffuse.mipFilter = .linear
        m.diffuse.intensity = 0.7
        m.blendMode = .alpha
        m.writesToDepthBuffer = false
        // Thin the clouds out at night so city lights show through.
        m.shaderModifiers = [.surface: """
        #pragma arguments
        float3 sunDir;
        #pragma transparent
        #pragma body
        float ndl = dot(normalize(_surface.normal), normalize(sunDir));
        _surface.diffuse = _surface.diffuse * mix(0.18, 1.0, smoothstep(-0.2, 0.15, ndl));
        """]
        m.setValue(NSValue(scnVector3: sunDirection), forKey: "sunDir")
        return m
    }

    /// Haze over the lit limb, drawn on a shell just above the surface.
    static func innerAtmosphere() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .add
        m.writesToDepthBuffer = false
        m.shaderModifiers = [.fragment: """
        #pragma arguments
        float3 sunDir;
        #pragma transparent
        #pragma body
        float3 n = normalize(_surface.normal);
        float3 v = normalize(_surface.view);
        float rim = 1.0 - saturate(dot(n, v));
        float ndl = dot(n, normalize(sunDir));
        float day = smoothstep(-0.28, 0.3, ndl);
        float a = (pow(rim, 2.2) * 1.5 + 0.06) * day;
        float3 c = mix(float3(1.0, 0.42, 0.18), float3(0.30, 0.56, 1.0), smoothstep(-0.12, 0.3, ndl));
        _output.color = float4(c * a, a);
        """]
        m.setValue(NSValue(scnVector3: sunDirection), forKey: "sunDir")
        return m
    }

    /// Glow beyond the limb, drawn on the inside of a larger shell so it fades into space.
    static func outerAtmosphere(shellRatio: Double) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.blendMode = .add
        m.cullMode = .front
        m.writesToDepthBuffer = false
        let limb = sqrt(1 - 1 / (shellRatio * shellRatio))
        m.shaderModifiers = [.fragment: """
        #pragma arguments
        float3 sunDir;
        float limb;
        #pragma transparent
        #pragma body
        float3 n = normalize(_surface.normal);
        float3 v = normalize(_surface.view);
        float x = saturate(abs(dot(n, v)) / limb);
        float3 nf = normalize(float3(n.x, n.y, abs(n.z)));
        float ndl = dot(nf, normalize(sunDir));
        float day = smoothstep(-0.35, 0.25, ndl);
        float a = pow(x, 4.0) * day * 1.3;
        float3 c = mix(float3(1.0, 0.4, 0.15), float3(0.26, 0.5, 1.0), smoothstep(-0.15, 0.25, ndl));
        _output.color = float4(c * a, a);
        """]
        m.setValue(NSValue(scnVector3: sunDirection), forKey: "sunDir")
        m.setValue(NSNumber(value: limb), forKey: "limb")
        return m
    }

    /// Fire detections. Every detection is a small square lying flat on the surface; this
    /// shader turns each square into a soft glowing ember with a hotter centre. The colour
    /// comes from the mesh (see FireMesh) and is pushed past white so the camera's bloom
    /// makes it glow. Embers are not lit by the Sun: a fire shows the same day or night.
    static func fireMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = whitePixel   // needed so UVs reach the shader
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .add
        // Each corner carries its square's centre in the normal slot. Pulling the corners
        // toward it shrinks every ember in place, so they stay the same size on screen
        // as the camera moves in.
        m.shaderModifiers = [.geometry: """
        #pragma arguments
        float emberScale;
        #pragma body
        float3 ec = normalize(_geometry.normal) * 1.0045;
        _geometry.position.xyz = ec + (_geometry.position.xyz - ec) * emberScale;
        """, .fragment: """
        #pragma arguments
        float emberTime;
        #pragma transparent
        #pragma body
        // The second texture coordinate also carries a number from 0 to 15 that differs from
        // ember to ember (see FireMesh), so they do not all flicker in step.
        float2 fuv = _surface.diffuseTexcoord;
        float fseed = floor(fuv.y * 0.5);
        fuv.y -= fseed * 2.0;
        fseed = fseed / 16.0;
        float2 fp = fuv * 2.0 - 1.0;
        float fr = length(fp);
        float3 fbase = _surface.diffuse.rgb;

        // An ember: a white-hot centre, a coloured body, and a wide soft halo, breathing slowly.
        // Embers add up where they overlap, so a dense fire front burns toward white.
        float fflick = 0.84 + 0.16 * sin(emberTime * (2.2 + 3.5 * fseed) + fseed * 41.0);
        float fedge = saturate(1.0 - fr);
        float fhalo = exp(-fr * fr * 5.0) * fedge * 0.42;
        float fbody = exp(-fr * fr * 22.0);
        float fcore = exp(-fr * fr * 90.0);
        float3 fglow = (fbase * (fhalo + fbody * 0.75) + mix(fbase, float3(1.0), 0.7) * fcore * 0.9) * fflick;
        float fga = saturate(fhalo + fbody);

        _output.color = float4(fglow * fga, fga);
        """]
        m.setValue(NSNumber(value: Float(0)), forKey: "emberTime")
        m.setValue(NSNumber(value: Float(1)), forKey: "emberScale")
        return m
    }

    /// The heat layer: a see-through shell just above the ground, painted with where the
    /// fires are densest (see HeatMap). It gives burning regions a glow that the individual
    /// sparks sit on, and pushes the hottest parts past white so the camera's bloom catches them.
    static func heatMaterial() -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = NSColor.clear
        m.diffuse.mipFilter = .linear
        m.diffuse.wrapS = .repeat
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        m.shaderModifiers = [.fragment: """
        #pragma arguments
        float heatAmount;
        #pragma transparent
        #pragma body
        float4 heat = _surface.diffuse * heatAmount;
        _output.color = float4(heat.rgb * (1.0 + 0.9 * heat.a), heat.a);
        """]
        m.setValue(NSNumber(value: Float(1)), forKey: "heatAmount")
        return m
    }

    static func glow(_ c: NSColor, additive: Bool = true) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.diffuse.contents = c
        m.emission.contents = c
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        if additive { m.blendMode = .add }
        return m
    }

    /// Cinematic camera: HDR with bloom, a touch of grain and fringe.
    static func camera(fov: CGFloat) -> SCNCamera {
        let c = SCNCamera()
        c.fieldOfView = fov
        c.zNear = 0.01
        c.zFar = 200
        c.wantsHDR = true
        c.exposureOffset = -0.1
        c.bloomIntensity = 0.45
        c.bloomThreshold = 1.0
        c.bloomBlurRadius = 14
        c.vignettingIntensity = 0.45
        c.vignettingPower = 1.2
        c.grainIntensity = 0.12
        c.grainScale = 2
        c.colorFringeStrength = 0.25
        return c
    }

    /// A paper tag rendered to a texture, for billboards inside the scene.
    static func label(_ text: String, value: String? = nil, dot: NSColor) -> (NSImage, CGFloat) {
        let ink = NSColor(Theme.ink)
        let s = NSMutableAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .semibold), .foregroundColor: ink])
        if let value {
            s.append(NSAttributedString(string: "  " + value, attributes: [.font: NSFont.systemFont(ofSize: 24, weight: .regular), .foregroundColor: NSColor(Theme.ink2)]))
        }
        let text = s.size()
        let size = NSSize(width: ceil(text.width) + 66, height: 48)
        let img = NSImage(size: size, flipped: false) { r in
            let body = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 16, yRadius: 16)
            NSColor(Theme.cream0).setFill(); body.fill()
            NSColor.white.withAlphaComponent(0.8).setStroke(); body.lineWidth = 1.5; body.stroke()
            let d = NSBezierPath(ovalIn: NSRect(x: 16, y: r.midY - 9, width: 18, height: 18))
            dot.setFill(); d.fill()
            ink.withAlphaComponent(0.7).setStroke(); d.lineWidth = 1.5; d.stroke()
            s.draw(at: NSPoint(x: 46, y: (r.height - text.height) / 2))
            return true
        }
        return (img, size.width / size.height)
    }
}

/// Unit-sphere position for a geographic or selenographic coordinate in SCNSphere's UV layout.
func sphereVector(lat: Double, lon: Double, radius: Double = 1) -> SCNVector3 {
    let phi = lat * .pi / 180, lam = lon * .pi / 180
    return SCNVector3(radius * cos(phi) * sin(lam), radius * sin(phi), radius * cos(phi) * cos(lam))
}

extension SCNVector3 {
    static func + (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: SCNVector3, b: SCNVector3) -> SCNVector3 { SCNVector3(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: SCNVector3, s: CGFloat) -> SCNVector3 { SCNVector3(a.x * s, a.y * s, a.z * s) }
    var length: CGFloat { sqrt(x * x + y * y + z * z) }
    var normalized: SCNVector3 { let l = max(length, 1e-9); return SCNVector3(x / l, y / l, z / l) }
    func cross(_ b: SCNVector3) -> SCNVector3 { SCNVector3(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
}
