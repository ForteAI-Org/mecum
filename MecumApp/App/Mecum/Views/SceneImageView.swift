import SeatBroker
import SwiftUI

/// The observed frame with every perceived element outlined and numbered.
struct SceneImageView: View {
    let observation: SceneObservation

    var body: some View {
        Image(decorative: observation.image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    ForEach(observation.elements) { element in
                        let rect = CGRect(x: element.bounds.minX * size.width, y: element.bounds.minY * size.height,
                                          width: element.bounds.width * size.width, height: element.bounds.height * size.height)
                        Rectangle()
                            .stroke(element.kind == "control" ? Color.orange : Color.cyan, lineWidth: 1)
                            .frame(width: rect.width, height: rect.height)
                            .position(x: rect.midX, y: rect.midY)
                        Text("\(element.index)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(2)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                            .position(x: rect.minX + 10, y: rect.minY + 7)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
