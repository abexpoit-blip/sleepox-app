import { Link } from "@tanstack/react-router";

/** Minimal markdown renderer for blog posts: headings, paragraphs, bullet lists, inline links and bold. */
export function MarkdownContent({ source }: { source: string }) {
  const blocks = source.trim().split(/\n\n+/);

  return (
    <div className="prose-blog space-y-6">
      {blocks.map((block, i) => {
        if (block.startsWith("## ")) {
          return (
            <h2 key={i} className="font-display text-2xl font-bold tracking-tight md:text-3xl">
              {block.slice(3).trim()}
            </h2>
          );
        }
        if (block.startsWith("- ")) {
          const items = block
            .split("\n")
            .filter((l) => l.startsWith("- "))
            .map((l) => l.slice(2));
          return (
            <ul key={i} className="space-y-2 pl-5 [&>li]:list-disc [&>li]:marker:text-primary">
              {items.map((it, j) => (
                <li key={j} className="text-base leading-relaxed text-muted-foreground">
                  {renderInline(it)}
                </li>
              ))}
            </ul>
          );
        }
        if (/^\d+\.\s/.test(block)) {
          const items = block
            .split("\n")
            .filter((l) => /^\d+\.\s/.test(l))
            .map((l) => l.replace(/^\d+\.\s/, ""));
          return (
            <ol key={i} className="space-y-2 pl-5 [&>li]:list-decimal [&>li]:marker:text-primary">
              {items.map((it, j) => (
                <li key={j} className="text-base leading-relaxed text-muted-foreground">
                  {renderInline(it)}
                </li>
              ))}
            </ol>
          );
        }
        return (
          <p key={i} className="text-base leading-relaxed text-muted-foreground md:text-lg">
            {renderInline(block)}
          </p>
        );
      })}
    </div>
  );
}

function renderInline(text: string): React.ReactNode[] {
  // Tokenize [label](href) and **bold**
  const nodes: React.ReactNode[] = [];
  const regex = /\[([^\]]+)\]\(([^)]+)\)|\*\*([^*]+)\*\*/g;
  let lastIndex = 0;
  let m: RegExpExecArray | null;
  let key = 0;
  while ((m = regex.exec(text)) !== null) {
    if (m.index > lastIndex) {
      nodes.push(text.slice(lastIndex, m.index));
    }
    if (m[1] && m[2]) {
      const href = m[2];
      const label = m[1];
      if (href.startsWith("/")) {
        nodes.push(
          <Link
            key={`k${key++}`}
            to={href}
            className="font-medium text-primary underline decoration-primary/40 underline-offset-4 hover:decoration-primary"
          >
            {label}
          </Link>,
        );
      } else {
        nodes.push(
          <a
            key={`k${key++}`}
            href={href}
            target="_blank"
            rel="noopener noreferrer"
            className="font-medium text-primary underline decoration-primary/40 underline-offset-4 hover:decoration-primary"
          >
            {label}
          </a>,
        );
      }
    } else if (m[3]) {
      nodes.push(
        <strong key={`k${key++}`} className="font-semibold text-foreground">
          {m[3]}
        </strong>,
      );
    }
    lastIndex = m.index + m[0].length;
  }
  if (lastIndex < text.length) nodes.push(text.slice(lastIndex));
  return nodes;
}
