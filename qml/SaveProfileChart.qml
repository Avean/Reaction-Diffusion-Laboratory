import QtQuick

// One variable of a save: its panels side by side, with a gap between them.
Canvas {
    id: chart

    property string title: ""
    property var panels: []

    onPanelsChanged: requestPaint()
    onWidthChanged: requestPaint()
    onHeightChanged: requestPaint()

    onPaint: {
        const context = getContext("2d")
        context.reset()
        context.fillStyle = "#ffffff"
        context.fillRect(0, 0, width, height)

        const left = 48
        const right = 10
        const top = 20
        const bottom = 8
        const plotWidth = Math.max(1, width - left - right)
        const plotHeight = Math.max(1, height - top - bottom)

        context.fillStyle = "#20252d"
        context.font = "bold 12px sans-serif"
        context.fillText(title, left, 14)

        context.strokeStyle = "#9ba6b5"
        context.lineWidth = 1
        context.beginPath()
        context.moveTo(left, top)
        context.lineTo(left, top + plotHeight)
        context.lineTo(left + plotWidth, top + plotHeight)
        context.stroke()

        const lines = panels || []
        let xmin = Infinity
        let xmax = -Infinity
        let ymin = Infinity
        let ymax = -Infinity
        for (const panel of lines) {
            for (let index = 0; index < panel.y.length; ++index) {
                xmin = Math.min(xmin, panel.x[index])
                xmax = Math.max(xmax, panel.x[index])
                ymin = Math.min(ymin, panel.y[index])
                ymax = Math.max(ymax, panel.y[index])
            }
        }
        if (!isFinite(xmin) || !isFinite(ymin))
            return
        if (ymax - ymin < 1e-12) {
            ymin -= 0.5
            ymax += 0.5
        }

        const xScale = plotWidth / Math.max(1e-12, xmax - xmin)
        const yScale = plotHeight / (ymax - ymin)

        context.fillStyle = "#68717d"
        context.font = "10px sans-serif"
        context.fillText(Number(ymax).toPrecision(3), 2, top + 8)
        context.fillText(Number(ymin).toPrecision(3), 2, top + plotHeight)

        context.strokeStyle = "#2563eb"
        context.lineWidth = 1.5
        for (const panel of lines) {
            context.beginPath()
            for (let index = 0; index < panel.y.length; ++index) {
                const x = left + (panel.x[index] - xmin) * xScale
                const y = top + plotHeight - (panel.y[index] - ymin) * yScale
                if (index === 0)
                    context.moveTo(x, y)
                else
                    context.lineTo(x, y)
            }
            context.stroke()
        }
    }
}
