import Foundation

/// A shared title block makes background behavior directly inspectable in the editor.
enum PageExample {
    static func make() -> Diagram {
        var diagram = Diagram();diagram.title = "Shared engineering pages"
        var background = DiagramPage(name:"Shared title block",width:960,height:640);background.isBackground = true
        var border = DiagramNode(x:20,y:20,text:"");border.width = 920;border.height = 600;border.fill = "#FFFFFF00";border.stroke = "#C4D0DE";border.strokeWidth = 1
        var title = DiagramNode(kind:.text,x:42,y:36,text:"NORTHSTAR  /  SYSTEM ATLAS");title.width = 650;title.height = 38;title.fontSize = 22;title.bold = true;title.textColor = "#244F7C";title.formatting.alignment = .left
        var footer = DiagramNode(kind:.text,x:42,y:583,text:"ENGINEERING     •     Internal     •     Revision 1.0");footer.width = 780;footer.height = 24;footer.fontSize = 11;footer.textColor = "#657990";footer.formatting.alignment = .left
        background.nodes = [border,title,footer]
        background.nodes[1].formatting.textBox = ShapeTextBox()
        background.nodes[2].formatting.textBox = ShapeTextBox()
        var first = DiagramPage(name:"System overview",width:960,height:640);first.backgroundPageID = background.id
        var a = DiagramNode(kind:.roundedRectangle,x:105,y:230,text:"Client application"),b = DiagramNode(kind:.roundedRectangle,x:400,y:230,text:"API service"),c = DiagramNode(kind:.cylinder,x:705,y:210,text:"Storage")
        a.width = 180;a.height = 90;b.width = 180;b.height = 90;c.width = 130;c.height = 130
        first.nodes = [a,b,c];first.edges = [DiagramEdge(source:a.id,target:b.id,label:"HTTPS"),DiagramEdge(source:b.id,target:c.id,label:"Queries")]
        var second = DiagramPage(name:"Delivery workflow",width:960,height:640);second.backgroundPageID = background.id
        let start = DiagramNode(kind:.roundedRectangle,x:105,y:230,text:"Prepare release"),review = DiagramNode(kind:.diamond,x:395,y:220,text:"Approved?"),ship = DiagramNode(kind:.document,x:695,y:230,text:"Deploy")
        second.nodes = [start,review,ship];second.edges = [DiagramEdge(source:start.id,target:review.id),DiagramEdge(source:review.id,target:ship.id,label:"Yes")]
        diagram.pages = [first,second,background];diagram.activePageID = first.id;return diagram
    }
}
