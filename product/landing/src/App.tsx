import { useEffect, useRef, useState } from "react";
import {
  ArrowUpRight,
  ArrowDown,
  Check,
  ChevronDown,
  X,
  Menu,
  Sparkles,
  FileText,
  Search,
  BookOpen,
  Users,
  LockKeyhole,
  Link2,
  MessageSquare,
  Plus,
  Pause,
  Play,
  Quote,
  CheckCheck,
  Layers3,
  Building2,
  ShieldCheck,
} from "lucide-react";
import HalftoneNebula from "./components/halftone-nebula";
const APP = (
  import.meta.env.VITE_APP_URL || "https://my-knowledge.duckdns.org"
).replace(/\/$/, "");
const LOGO = `${import.meta.env.BASE_URL}axi-logo.webp`;
const SKY = {
  voidColor: "#050609",
  hazeColor: "#111526",
  duskColor: "#1a2245",
  wineColor: "#273571",
  crimsonColor: "#3656e8",
  hotColor: "#9faaff",
  starColor: "#f2f4ff",
  planet: false,
  pixel: 5,
  sparkles: 7,
  stars: 0.7,
  bandAngle: 0.5,
  bandWidth: 0.28,
  bandOffset: 0.6,
  speed: 0.4,
  vignette: 0.75,
  lens: 0.35,
  density: 0.43,
};
const examples = [
  {
    label: "Onboard a teammate",
    question: "What should a new teammate do in their first week?",
    intro: "Here’s the first-week plan, from your team’s onboarding guide.",
    steps: [
      "Day 1: Meet your buddy and get access to the tools you need.",
      "Days 2–3: Read the team handbook and meet the people you’ll work with.",
      "Days 4–5: Join a project and agree your first goals with your manager.",
    ],
    source: "New teammate guide",
    type: "People & culture",
    icon: Users,
    excerpt:
      "Every new teammate is assigned a buddy on day one. Tool access is arranged before their first meeting. Days two and three are for reading the handbook and meeting the team. By the end of week one, the teammate joins a project and sets their first goals with their manager.",
    date: "People team · Example document",
  },
  {
    label: "Find a project update",
    question: "What’s left before the website launch?",
    intro:
      "The launch plan lists three remaining items before the site goes live.",
    steps: [
      "Design: Approve the final mobile layouts.",
      "Content: Finish the product pages and check all links.",
      "Launch: Complete the final review and connect the domain.",
    ],
    source: "Website launch plan",
    type: "Projects",
    icon: Layers3,
    excerpt:
      "The final launch checklist contains three open items: mobile layout approval from the design team; completed product page copy and a full link check from the content team; and a final review followed by the domain connection. The project owner coordinates sign-off.",
    date: "Project team · Example document",
  },
  {
    label: "Look up a policy",
    question: "How do I request time off?",
    intro: "Your team handbook explains the process in three steps.",
    steps: [
      "Check the team calendar before choosing your dates.",
      "Send your dates to your manager with your handover notes.",
      "Once confirmed, add the time off to the shared calendar.",
    ],
    source: "Team handbook",
    type: "Company policies",
    icon: BookOpen,
    excerpt:
      "To request planned time off, first check the shared team calendar. Send the requested dates and handover notes to your manager. When the dates are confirmed, update the shared calendar so your teammates can plan around your absence.",
    date: "People team · Example document",
  },
];
function Brand() {
  return (
    <span className="brand">
      <img src={LOGO} alt="" width="40" height="40" />
      <span>
        <strong>
          22nd X AI<span className="brand-dot">.</span>
        </strong>
        <span className="brand-caption">Company knowledge</span>
      </span>
    </span>
  );
}
export default function Home() {
  const [mobileMenu, setMobileMenu] = useState(false),
    [paused, setPaused] = useState(false),
    [active, setActive] = useState(0),
    [documentOpen, setDocumentOpen] = useState(false),
    [useCase, setUseCase] = useState(0),
    [faq, setFaq] = useState<number | null>(null),
    [revealsReady, setRevealsReady] = useState(false);
  const closeRef = useRef<HTMLButtonElement>(null),
    citationRef = useRef<HTMLButtonElement>(null),
    current = examples[active];
  useEffect(() => {
    const io = new IntersectionObserver(
      (entries) =>
        entries.forEach((e) => {
          if (e.isIntersecting) {
            e.target.classList.add("revealed");
            io.unobserve(e.target);
          }
        }),
      { threshold: 0.08 },
    );
    document.querySelectorAll(".reveal").forEach((n) => io.observe(n));
    setRevealsReady(true);
    return () => io.disconnect();
  }, []);
  useEffect(() => {
    if (!documentOpen) return;
    const before = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    closeRef.current?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") setDocumentOpen(false);
      if (e.key === "Tab") {
        e.preventDefault();
        closeRef.current?.focus();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => {
      document.body.style.overflow = before;
      document.removeEventListener("keydown", onKey);
      citationRef.current?.focus();
    };
  }, [documentOpen]);
  const cases = [
    {
      name: "New teammates",
      number: "01",
      title: (
        <>
          First day.
          <br />
          Already in the know.
        </>
      ),
      description:
        "Give new teammates a place to ask the small questions, learn the company and find the documents that matter.",
      prompt: "Where do I start?",
      answer:
        "Your first-week guide, team handbook and project brief are right here.",
      tags: ["Onboarding", "Team knowledge", "Company policies"],
      icon: Users,
    },
    {
      name: "Busy teams",
      number: "02",
      title: (
        <>
          Less searching.
          <br />
          More moving forward.
        </>
      ),
      description:
        "Find the right process, pick up a project and check a policy without asking someone to find the link again.",
      prompt: "What’s the next step?",
      answer:
        "The website launch plan has three open items. Here’s the checklist and its source.",
      tags: ["Projects", "Processes", "Everyday questions"],
      icon: Layers3,
    },
    {
      name: "Company owners",
      number: "03",
      title: (
        <>
          Your company.
          <br />
          Better connected.
        </>
      ),
      description:
        "Bring your team into its own workspace. Make company knowledge useful, without making customers set up an AI provider.",
      prompt: "Can everyone find this?",
      answer:
        "Invite your team, add the company’s documents and start asking questions.",
      tags: ["Your workspace", "Member invitations", "Company separation"],
      icon: Building2,
    },
  ];
  const faqs = [
    [
      "What is 22nd X AI Knowledge?",
      "A company knowledge base with AI search and chat. Add your documents, connect supported sources and let your team ask questions with citations back to the original material.",
    ],
    [
      "Does each company get its own workspace?",
      "Yes. A new business owner can create a separate company workspace and invite teammates. Company knowledge, conversations and connected sources stay within that workspace’s access rules.",
    ],
    [
      "Do we need our own AI API key?",
      "No. Our model is configured when your company workspace is created, so your team can start using chat without opening a separate model-provider account.",
    ],
    [
      "How do we bring in our knowledge?",
      "Start by uploading your documents. Your company admin can also configure the supported source connectors available in the app. You choose what to add and who should have access.",
    ],
    [
      "How do teammates join?",
      "Invite their email address from your company’s admin panel, then share the signup page. They sign up using that address and join your company as a member. Automatic invitation email delivery isn’t configured in the current development product.",
    ],
    [
      "Can I check where an answer came from?",
      "Yes. Knowledge-grounded answers can include citations that let you open the source material. AI answers can still be mistaken, so use the cited documents to verify details that matter.",
    ],
  ];
  const TeamIcon = cases[useCase].icon;
  return (
    <div className={`site ${revealsReady ? "reveals-ready" : ""}`}>
      <a href="#main" className="skip-link">
        Skip to content
      </a>
      <header className="site-header">
        <div className="header-inner">
          <a
            href="#home"
            className="brand-link"
            aria-label="22nd X AI Knowledge home"
          >
            <Brand />
          </a>
          <nav aria-label="Main navigation" className="nav-pill">
            <a href="#platform">Platform</a>
            <a href="#how-it-works">How it works</a>
            <a href="#teams">For your team</a>
          </nav>
          <div className="header-actions">
            <a href={`${APP}/auth/login`} className="login-link">
              Log in
              <ArrowUpRight size={13} />
            </a>
            <a
              className="button button-white button-small"
              href={`${APP}/auth/signup`}
            >
              Get started
              <ArrowUpRight size={15} />
            </a>
            <button
              className="menu-button"
              onClick={() => setMobileMenu(!mobileMenu)}
              aria-expanded={mobileMenu}
              aria-label={mobileMenu ? "Close navigation" : "Open navigation"}
            >
              {mobileMenu ? <X /> : <Menu />}
            </button>
          </div>
        </div>
        {mobileMenu && (
          <nav aria-label="Mobile navigation" className="mobile-nav">
            {[
              ["Platform", "#platform"],
              ["How it works", "#how-it-works"],
              ["For your team", "#teams"],
              ["Questions", "#faq"],
            ].map(([name, href]) => (
              <a key={href} href={href} onClick={() => setMobileMenu(false)}>
                {name}
                <ArrowUpRight size={17} />
              </a>
            ))}
            <a href={`${APP}/auth/login`}>
              Log in
              <ArrowUpRight size={17} />
            </a>
          </nav>
        )}
      </header>
      <main id="main">
        <div className="hero" id="home">
          <div className="hero-sky">
            <HalftoneNebula
              height="100%"
              params={{ ...SKY, speed: paused ? 0 : SKY.speed }}
              maxDpr={1.25}
              interactive={!paused}
              className="nebula"
            />
          </div>
          <div className="hero-shade" />
          <div className="hero-content wrap">
            <div className="eyebrow hero-eyebrow">
              <span className="signal" />
              THE KNOWLEDGE BASE FOR YOUR COMPANY
            </div>
            <h1>
              All your knowledge.
              <br />
              <span className="pixel-type">One brilliant mind.</span>
            </h1>
            <p className="hero-description">
              Your company knows a lot. Now everyone can find it.
              <br className="desktop-break" /> Turn scattered documents into
              clear answers, backed by sources.
            </p>
            <div className="hero-buttons">
              <a href={`${APP}/auth/signup`} className="button button-white">
                Create your company
                <ArrowUpRight size={19} />
              </a>
              <a href="#platform" className="button button-ghost">
                See it in action
                <ArrowDown size={17} />
              </a>
            </div>
            <p className="hero-note">
              <Check size={13} />
              Your own workspace
              <span />
              No model setup
            </p>
          </div>
          <div className="hero-bottom wrap">
            <span>More clarity. Less busywork.</span>
            <a href="#platform">
              MEET YOUR COMPANY’S KNOWLEDGE
              <ArrowDown size={13} />
            </a>
            <button
              onClick={() => setPaused(!paused)}
              aria-label={
                paused
                  ? "Play background animation"
                  : "Pause background animation"
              }
            >
              {paused ? <Play size={12} /> : <Pause size={12} />}
              <span>{paused ? "Play motion" : "Pause motion"}</span>
            </button>
          </div>
        </div>

        <section
          className="platform-section wrap"
          id="platform"
          aria-labelledby="platform-title"
        >
          <div className="section-top reveal">
            <span className="eyebrow">01 / FROM QUESTION TO CLARITY</span>
            <span className="section-side">Ask. Understand. Move forward.</span>
          </div>
          <div className="section-heading reveal">
            <h2 id="platform-title">
              Stop hunting for answers.
              <br />
              <span>Start a conversation.</span>
            </h2>
            <p>
              A handbook, a project plan, that one document.
              <br />
              Bring it together. Ask in your own words.
            </p>
          </div>
          <div className="product-window reveal">
            <div className="window-bar">
              <span className="window-dots">
                <i />
                <i />
                <i />
              </span>
              <span>
                <LockKeyhole size={11} />
                22nd X AI / Your company workspace
              </span>
              <span className="example-label">
                <span />
                Interactive example
              </span>
            </div>
            <div className="product-body">
              <aside
                className="product-sidebar"
                aria-label="Illustrative workspace sidebar"
              >
                <div className="workspace-company">
                  <span className="company-icon">N</span>
                  <span>
                    Northstar<span>Company workspace</span>
                  </span>
                  <ChevronDown size={14} />
                </div>
                <div className="new-question">
                  <Plus size={15} />
                  New conversation
                </div>
                <div className="sidebar-item selected">
                  <MessageSquare size={16} />
                  Ask your company
                </div>
                <div className="sidebar-item">
                  <BookOpen size={16} />
                  Knowledge
                </div>
                <div className="sidebar-item">
                  <Users size={16} />
                  Members
                </div>
                <p className="sidebar-label">YOUR KNOWLEDGE</p>
                {[
                  "Team handbook",
                  "New teammate guide",
                  "Website launch plan",
                ].map((name) => (
                  <div key={name} className="sidebar-file">
                    <FileText size={14} />
                    {name}
                  </div>
                ))}
                <div className="sidebar-footer">
                  <span className="avatar">JD</span>
                  <span>
                    Jordan Davis<small>Company owner</small>
                  </span>
                </div>
              </aside>
              <div className="product-chat">
                <div className="chat-top">
                  <span>
                    <Sparkles size={14} />
                    Company assistant
                  </span>
                  <span className="workspace-private">
                    <LockKeyhole size={12} />
                    Your workspace
                  </span>
                </div>
                <div className="chat-content">
                  <div className="preview-intro">
                    <span className="assistant-mark">
                      <img src={LOGO} alt="" width="30" height="30" />
                    </span>
                    <span>BIG QUESTIONS. CLEAR ANSWERS.</span>
                  </div>
                  <h3>What would you like to know?</h3>
                  <div
                    className="question-tabs"
                    role="tablist"
                    aria-label="Example questions"
                  >
                    {examples.map((e, i) => (
                      <button
                        key={e.label}
                        id={`question-tab-${i}`}
                        role="tab"
                        aria-selected={i === active}
                        aria-controls="example-answer"
                        tabIndex={i === active ? 0 : -1}
                        className={i === active ? "active" : ""}
                        onClick={() => setActive(i)}
                        onKeyDown={(ev) => {
                          if (
                            ev.key === "ArrowRight" ||
                            ev.key === "ArrowLeft"
                          ) {
                            ev.preventDefault();
                            const next =
                              (active + (ev.key === "ArrowRight" ? 1 : 2)) % 3;
                            setActive(next);
                            document
                              .getElementById(`question-tab-${next}`)
                              ?.focus();
                          }
                        }}
                      >
                        <e.icon size={13} />
                        {e.label}
                      </button>
                    ))}
                  </div>
                  <div
                    className="example-answer"
                    id="example-answer"
                    role="tabpanel"
                    aria-labelledby={`question-tab-${active}`}
                    key={active}
                  >
                    <div className="user-question">
                      <span>{current.question}</span>
                      <span className="avatar">JD</span>
                    </div>
                    <div className="assistant-answer">
                      <img
                        className="answer-logo"
                        src={LOGO}
                        alt="22nd X AI"
                        width="28"
                        height="28"
                      />
                      <div>
                        <div className="answer-status">
                          <CheckCheck size={12} />
                          Answered from your knowledge
                        </div>
                        <p>{current.intro}</p>
                        <ol>
                          {current.steps.map((s, i) => (
                            <li key={s}>
                              <span>{i + 1}</span>
                              {s}
                            </li>
                          ))}
                        </ol>
                        <div className="answer-sources">
                          <span>SOURCES</span>
                          <button
                            ref={citationRef}
                            onClick={() => setDocumentOpen(true)}
                            aria-haspopup="dialog"
                          >
                            <FileText size={13} />
                            {current.source}
                            <span className="citation-number">1</span>
                            <ArrowUpRight size={12} />
                          </button>
                        </div>
                      </div>
                    </div>
                  </div>
                  <a className="demo-composer" href={`${APP}/auth/signup`}>
                    <span>Ask your company anything…</span>
                    <span className="composer-send">
                      <ArrowUpRight size={17} />
                    </span>
                  </a>
                  <p className="demo-disclaimer">
                    Illustrative questions and documents. Explore the source
                    citation.
                  </p>
                </div>
              </div>
            </div>
          </div>
          <div className="feature-strip reveal">
            <span>
              <Search size={16} />
              Find what matters
            </span>
            <span>
              <Quote size={16} />
              Know where it came from
            </span>
            <span>
              <ShieldCheck size={16} />
              Keep companies separate
            </span>
          </div>
        </section>

        <section
          className="connected-section"
          aria-labelledby="connected-title"
        >
          <div className="wrap connected-grid">
            <div className="connected-copy reveal">
              <span className="eyebrow">02 / KNOWLEDGE, CONNECTED</span>
              <h2 id="connected-title">
                Scattered everywhere.
                <br />
                <span>Useful, together.</span>
              </h2>
              <p>
                Good knowledge shouldn’t get lost between tools. Bring your
                documents and supported sources into one place your team can
                ask.
              </p>
              <a href={`${APP}/auth/signup`} className="text-link">
                Put your knowledge to work
                <ArrowUpRight size={18} />
              </a>
              <div className="connected-facts">
                <div>
                  <FileText size={19} />
                  <span>
                    Upload your documents
                    <small>Handbooks, guides and project knowledge.</small>
                  </span>
                </div>
                <div>
                  <Link2 size={19} />
                  <span>
                    Connect supported sources
                    <small>
                      Keep the original context close to the answer.
                    </small>
                  </span>
                </div>
              </div>
            </div>
            <div
              className="knowledge-map reveal"
              aria-label="Illustration: documents and source connectors form company knowledge"
            >
              <div className="map-grid" />
              <svg
                className="map-lines"
                viewBox="0 0 540 480"
                aria-hidden="true"
              >
                <path d="M120 95 C120 220 270 140 270 240 M410 105 C410 210 270 150 270 240 M95 295 C160 295 150 240 270 240 M420 300 C330 300 370 240 270 240 M240 405 L270 240" />
              </svg>
              <div className="map-source source-one">
                <FileText />
                <span>
                  Team handbook<small>COMPANY DOCUMENT</small>
                </span>
              </div>
              <div className="map-source source-two">
                <Layers3 />
                <span>
                  Project plans<small>TEAM KNOWLEDGE</small>
                </span>
              </div>
              <div className="map-source source-three">
                <Link2 />
                <span>
                  Connected tools<small>SUPPORTED SOURCES</small>
                </span>
              </div>
              <div className="map-source source-four">
                <BookOpen />
                <span>
                  Policies & guides<small>COMPANY DOCUMENTS</small>
                </span>
              </div>
              <div className="map-core">
                <div>
                  <img src={LOGO} alt="" width="58" height="58" />
                </div>
                <span>
                  Your company’s
                  <br />
                  knowledge
                </span>
              </div>
              <div className="map-result">
                <Sparkles size={17} />
                <span>One question. A clearer answer.</span>
                <Check size={13} />
              </div>
            </div>
          </div>
        </section>

        <section
          className="steps-section wrap"
          id="how-it-works"
          aria-labelledby="steps-title"
        >
          <div className="section-top reveal">
            <span className="eyebrow">03 / YOUR FIRST CLEAR ANSWER</span>
            <span className="section-side">A simpler start.</span>
          </div>
          <div className="section-heading reveal">
            <h2 id="steps-title">
              From “where is it?”
              <br />
              <span>to “here it is.”</span>
            </h2>
            <p>
              A place for your company.
              <br />
              An easier way for your team.
            </p>
          </div>
          <div className="steps-grid">
            <article className="step reveal">
              <div className="step-visual step-workspace">
                <div className="mini-window">
                  <span className="mini-label">
                    <Building2 size={14} />
                    YOUR COMPANY
                  </span>
                  <div className="mini-field">
                    Northstar
                    <span>
                      <Check size={13} />
                    </span>
                  </div>
                  <div className="mini-person">
                    <span className="avatar">JD</span>
                    <span>
                      Jordan Davis<small>Workspace owner</small>
                    </span>
                    <span className="mini-role">Admin</span>
                  </div>
                </div>
              </div>
              <span className="step-number">01</span>
              <h3>Make it yours.</h3>
              <p>
                Create your company workspace.
                <br />
                AI chat is ready when you arrive.
              </p>
            </article>
            <article className="step reveal">
              <div className="step-visual step-files">
                <div className="file-stack">
                  <div>
                    <FileText />
                    <span>Team handbook.pdf</span>
                    <Check size={13} />
                  </div>
                  <div>
                    <FileText />
                    <span>Project brief.docx</span>
                    <Check size={13} />
                  </div>
                  <div>
                    <Link2 />
                    <span>Your connected sources</span>
                    <Plus size={13} />
                  </div>
                </div>
              </div>
              <span className="step-number">02</span>
              <h3>Bring what you know.</h3>
              <p>
                Add documents and supported sources.
                <br />
                Give the answer somewhere to start.
              </p>
            </article>
            <article className="step reveal">
              <div className="step-visual step-answer">
                <div className="mini-conversation">
                  <div>
                    <MessageSquare size={13} />
                    <span>What’s the next step?</span>
                  </div>
                  <div>
                    <Sparkles size={15} />
                    <span>
                      Here’s the plan.
                      <small>
                        <FileText size={11} />
                        Project brief<span>1</span>
                      </small>
                    </span>
                  </div>
                </div>
              </div>
              <span className="step-number">03</span>
              <h3>Get everyone in the know.</h3>
              <p>
                Invite teammates. Ask questions.
                <br />
                Find the source and move forward.
              </p>
            </article>
          </div>
        </section>

        <section
          className="teams-section"
          id="teams"
          aria-labelledby="teams-title"
        >
          <div className="wrap">
            <div className="section-top reveal">
              <span className="eyebrow">04 / BUILT AROUND YOUR PEOPLE</span>
              <span className="section-side">
                Same knowledge. Different questions.
              </span>
            </div>
            <div className="teams-heading reveal">
              <h2 id="teams-title">
                A little less asking around.
                <br />
                <span>A lot more getting ahead.</span>
              </h2>
            </div>
            <div className="teams-layout reveal">
              <div
                className="team-tabs"
                role="tablist"
                aria-label="Explore by team"
              >
                {cases.map((c, i) => (
                  <button
                    key={c.name}
                    id={`case-tab-${i}`}
                    role="tab"
                    aria-selected={i === useCase}
                    aria-controls="team-panel"
                    onClick={() => setUseCase(i)}
                  >
                    <span>{c.number}</span>
                    {c.name}
                    <ArrowUpRight size={20} />
                  </button>
                ))}
              </div>
              <div
                className="team-panel"
                id="team-panel"
                role="tabpanel"
                aria-labelledby={`case-tab-${useCase}`}
              >
                <div className="team-detail" key={useCase}>
                  <span className="team-icon">
                    <TeamIcon size={23} />
                  </span>
                  <h3>{cases[useCase].title}</h3>
                  <p>{cases[useCase].description}</p>
                  <div className="team-tags">
                    {cases[useCase].tags.map((tag) => (
                      <span key={tag}>{tag}</span>
                    ))}
                  </div>
                </div>
                <div className="team-example">
                  <span className="mini-label">ILLUSTRATIVE TEAM QUESTION</span>
                  <div className="team-question">
                    <span className="avatar">JD</span>
                    {cases[useCase].prompt}
                  </div>
                  <div className="team-response">
                    <img src={LOGO} alt="" width="26" height="26" />
                    <p>{cases[useCase].answer}</p>
                  </div>
                  <div className="team-example-footer">
                    <CheckCheck size={13} />
                    Clarity, with context.
                  </div>
                </div>
              </div>
            </div>
          </div>
        </section>

        <section
          className="workspace-section wrap"
          aria-labelledby="workspace-title"
        >
          <div className="workspace-content reveal">
            <span className="eyebrow">05 / YOUR COMPANY’S SPACE</span>
            <h2 id="workspace-title">
              Your knowledge.
              <br />
              <span>Your people.</span>
              <br />
              Your workspace.
            </h2>
            <p>
              A separate place for every company. Invite your team, manage your
              sources and give people access to the knowledge they need.
            </p>
            <a href={`${APP}/auth/signup`} className="text-link">
              Create your company workspace
              <ArrowUpRight size={18} />
            </a>
          </div>
          <div className="workspace-visual reveal">
            <div className="company-card">
              <div className="company-card-heading">
                <span className="company-icon">N</span>
                <div>
                  Northstar<small>Company workspace</small>
                </div>
                <LockKeyhole size={17} />
              </div>
              <div className="company-member">
                <span className="avatar">JD</span>
                <span>
                  Jordan<small>Company owner</small>
                </span>
                <span className="role">Admin</span>
              </div>
              <div className="company-member">
                <span className="avatar avatar-blue">AK</span>
                <span>
                  Alex<small>Your teammate</small>
                </span>
                <span className="role">Member</span>
              </div>
              <div className="company-member">
                <span className="avatar avatar-grey">SM</span>
                <span>
                  Sam<small>Joining your company</small>
                </span>
                <span className="role invited">Invited</span>
              </div>
              <div className="company-card-footer">
                <ShieldCheck size={15} />
                Company knowledge stays in your workspace.
              </div>
            </div>
            <div className="separate-company">
              <Building2 size={16} />
              <span>Another company. Its own space.</span>
              <LockKeyhole size={13} />
            </div>
            <span className="workspace-caption">
              Illustrative companies and teammates
            </span>
          </div>
        </section>

        <section
          className="faq-section wrap"
          id="faq"
          aria-labelledby="faq-title"
        >
          <div className="faq-heading reveal">
            <span className="eyebrow">06 / A LITTLE MORE CLARITY</span>
            <h2 id="faq-title">
              Good questions.
              <br />
              <span>Clear answers.</span>
            </h2>
            <a
              href="https://axi-solutions.vercel.app/#contact"
              className="text-link"
            >
              Have something else in mind?
              <ArrowUpRight size={16} />
            </a>
          </div>
          <div className="faq-list reveal">
            {faqs.map(([q, a], i) => (
              <div key={q} className={`faq-item ${faq === i ? "open" : ""}`}>
                <button
                  aria-expanded={faq === i}
                  aria-controls={`faq-answer-${i}`}
                  onClick={() => setFaq(faq === i ? null : i)}
                >
                  {q}
                  <Plus size={19} />
                </button>
                <div id={`faq-answer-${i}`} hidden={faq !== i}>
                  <p>{a}</p>
                </div>
              </div>
            ))}
          </div>
        </section>
        <section className="closing-section" aria-labelledby="closing-title">
          <div className="closing-dots" aria-hidden="true" />
          <div className="wrap closing-content reveal">
            <span className="eyebrow">YOUR COMPANY. ALL TOGETHER.</span>
            <h2 id="closing-title">
              Less lost knowledge.
              <br />
              <span className="pixel-type">More brilliant work.</span>
            </h2>
            <p>Your next clear answer starts with what you already know.</p>
            <a href={`${APP}/auth/signup`} className="button button-white">
              Create your company
              <ArrowUpRight size={19} />
            </a>
          </div>
        </section>
      </main>
      <footer className="site-footer wrap">
        <div className="footer-top">
          <a
            href="#home"
            className="brand-link"
            aria-label="Back to 22nd X AI Knowledge home"
          >
            <Brand />
          </a>
          <span>More growth. Less busywork.</span>
          <a href="https://axi-solutions.vercel.app/" className="text-link">
            Meet 22nd X AI
            <ArrowUpRight size={16} />
          </a>
        </div>
        <div className="footer-bottom">
          <span>© {new Date().getFullYear()} 22nd X AI</span>
          <span>Company knowledge, connected.</span>
          <div>
            <a href={`${APP}/auth/login`}>Log in</a>
            <a href="#faq">Questions</a>
            <a href="#home">Back to top ↑</a>
          </div>
        </div>
      </footer>
      {documentOpen && (
        <div className="modal-backdrop" onClick={() => setDocumentOpen(false)}>
          <div
            role="dialog"
            aria-modal="true"
            aria-labelledby="source-title"
            className="source-dialog"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="source-dialog-header">
              <span>
                <FileText size={16} />
                SOURCE PREVIEW
              </span>
              <button
                ref={closeRef}
                onClick={() => setDocumentOpen(false)}
                aria-label="Close source preview"
              >
                <X size={21} />
              </button>
            </div>
            <div className="source-document">
              <span className="eyebrow">{current.type}</span>
              <h2 id="source-title">{current.source}</h2>
              <p className="source-meta">{current.date}</p>
              <p className="source-text">{current.excerpt}</p>
              <div className="source-explainer">
                <Quote size={18} />
                <p>
                  The answer points back to this source, so your team can check
                  the context.
                </p>
              </div>
              <p className="source-example-note">
                This document is an illustrative example for the landing page.
              </p>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
