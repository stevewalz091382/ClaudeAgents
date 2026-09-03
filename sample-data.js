// Sample dataset ("Load Sample Data" button). Purely for demo/testing purposes —
// mirrors the shape of a real Design Technology Program status update.
// Fields match the required import/export format:
// Quarter, Strategic Pillar, Project Name, Recent Risks and Blockers, Accomplishments/Updates,
// Approximate Completion Percentage, Project Manager, Initiative Description
// (Quarter is applied uniformly to all rows when this dataset is loaded, not stored per-row here.)
window.SAMPLE_DATA = [
  {
    pillar: `Data`,
    project: `Content Strategy (Avail Platform, Creation, Maintenance, Shared Parameters)`,
    risks: `IP watermarking is at different stages across business groups; each group needs a plan to close the gap before general release.`,
    updates: `ABG rollout on April 6th, 2026. On boarding training has been provided. Approx 1000 users on Avail at the moment; ENG rollout anticipated for beginning of July. Eng currently reviewing and consolidating content, applying consolidated shared parameters and IP prior to upload into Avail; Enclave solution has been provided by Avail and HDR is currently testing. Still needs to run through Summit7 for review/approval.`,
    pct: 60,
    pm: `Joe Campisi`,
    description: `Develop Avail platform content governance, create shared parameter libraries, and publish maintenance workflows for consistent content strategy.`
  },
  {
    pillar: `Data`,
    project: `Expand Premium Data Service`,
    risks: `Awaiting legal review before the datasets can be published externally; timeline depends on legal's queue.`,
    updates: `Expand Premium Data Service concept and make available across platforms working with Morgan Renter, it has been approved for a SPM project, we have identified 5 datasets from Cross Sector and ABG. These are being defined/built into a process prototype in ServiceNow.`,
    pct: 12,
    pm: `Dwayne Hansen`,
    description: `Establish Procedure within ServiceNow for identifying Premium Data Services, create Data Cards within the Data Catalog, Knowledgebase article on each Premium Data Service (Access, license of usage, Renewals, etc.)`
  },
  {
    pillar: `Data`,
    project: `Data Warehouse Standards (project profiling and tagging models, Design use for all Class A products)`,
    updates: `Meetings to begin in June.`,
    pct: 0,
    pm: `Shawn Nelson`,
    description: `Establish project profiling standards, define tagging models for Class A products, and create governance documentation for data warehouse usage.`
  },
  {
    pillar: `Data`,
    project: `Value Creation`,
    updates: `Not started.`,
    pct: 0,
    pm: `Chad Tenbroek`,
    description: `Identify KPIs to understand Quality gains, efficiency, financial, employee experience.`
  },
  {
    pillar: `Digital Platforms`,
    project: `Legacy Products Transition Plan/Framework`,
    updates: `Early draft framework established.`,
    pct: 5,
    pm: `Mitch Williams`,
    description: `Create migration roadmap for legacy products, define decommissioning procedures, and publish knowledge articles for transition support.`
  },
  {
    pillar: `Digital Platforms`,
    project: `Streamlined BIM/GIS Ecosystem for Design Efficiency`,
    updates: `Not started.`,
    pct: 0,
    pm: `Bridget Brown`,
    description: `Develop unified BIM/GIS workflows, establish interoperability standards, and create training modules for efficient digital delivery.`
  },
  {
    pillar: `Digital Platforms`,
    project: `Helix Platform, CMMS Integration & Adoption`,
    updates: `25% complete on our discipline data definition effort. The I&C team has provided their standard asset and property definitions. We will begin work on the Electrical discipline over the next few weeks. We have initiated one large scale pilot with CCWA out of the Tampa office.`,
    pct: 25,
    pm: `Chad Tenbroek`,
    description: `Define Helix data standards, integrate CMMS workflows, create adoption playbook, and publish governance guidelines for platform usage.`
  },
  {
    pillar: `Digital Platforms`,
    project: `Expansion of HDR Enclave Capabilities`,
    updates: `Continued discussions and testing amongst Federal, DDLs and Corp Tech stakeholders.`,
    pct: 10,
    pm: `Jim Greve`,
    description: `Enhance Enclave infrastructure for scalability, implement secure data access protocols, and develop onboarding documentation for expanded usage.`
  },
  {
    pillar: `Execution & Delivery`,
    project: `CAD/BIM Production Reporting & KPIs`,
    risks: `Waiting on Autodesk to provide a supported process for exporting cloud usage data; no committed delivery date yet.`,
    updates: `Bentley - actively developing a solution to monitor active vs idle activity in products; Autodesk - awaiting a dedicated supported process for Autodesk to provide exports of data points being collected in cloud and product.`,
    pct: 10,
    pm: `Dan Prokop`,
    description: `Design automated reporting dashboards, implement KPI tracking framework, and publish usage metric guidelines for project teams.`
  },
  {
    pillar: `Execution & Delivery`,
    project: `Project Planning & Execution Strategy`,
    risks: `Rollout to remaining business groups depends on PMIS integration work that is not yet scheduled.`,
    updates: `DDP requirements collected, development of DDP app and integration of dashboard is underway; SharePoint sites and guidance for interim and permanent solutions have been developed and made available in Digital Design Community.`,
    pct: 65,
    pm: `Steve Walz`,
    description: `Develop standardized planning workflows, create execution strategy templates, and publish best practices for digital delivery.`
  },
  {
    pillar: `Execution & Delivery`,
    project: `BIM-First Workflow & Training Curriculum`,
    updates: `Not started.`,
    pct: 0,
    pm: `Dan Prokop`,
    description: `Create BIM-first workflow documentation, develop training modules, and publish adoption guidelines for project teams.`
  },
  {
    pillar: `Execution & Delivery`,
    project: `Standards and Practices`,
    updates: `Not started.`,
    pct: 0,
    pm: `Chad Tenbroek`,
    description: `Standardized Project Setup Process: Civil 3D and Revit; 100% WBG detailed design projects have DDP.`
  },
  {
    pillar: `Execution & Delivery`,
    project: `ACC Adoption for Autodesk Projects`,
    updates: `DDC ACC SharePoint site updated to reflect updated Forma branding. Training and overview videos have been developed and made available. Working with Autodesk to get access to HDR user data/metrics in Forma to evaluate adoption; working with PMIS Lead to establish enablement requirements and support for teams across all BGs.`,
    pct: 40,
    pm: `Tyson Bruntz`,
    description: `Implement ACC onboarding framework, create integration guides, and publish governance for Autodesk project workflows.`
  },
  {
    pillar: `Implementation`,
    project: `Streamline DDD Best Practices Access`,
    updates: `Inventory of Digital Practice and Digital Design Community channels, along with activity, overlaps, etc. identified. Cleanup and consolidation will begin in June; Copilot Agent has been created and will be available on DDC SharePoint site by end of May for all users to quickly search for guidance and assistance.`,
    pct: 30,
    pm: `Steve Walz`,
    description: `Create centralized best practices repository, implement search optimization, and publish quick reference guides for DDD workflows.`
  },
  {
    pillar: `Implementation`,
    project: `Federal Model Manager Technical Network`,
    updates: `Key Model Managers across all BGs are being identified.`,
    pct: 10,
    pm: `Jim Greve`,
    description: `Develop practice group governance, create training resources, and publish collaboration guidelines for federal model managers.`
  },
  {
    pillar: `Implementation`,
    project: `DDD Roles & Career Path Development`,
    updates: `Planned for H2 2026. ATO and BES to lead competency and progression frameworks.`,
    pct: 0,
    pm: `Pratibha Basrao`,
    description: `Define career progression frameworks, create role competency models, and publish development resources for DDD roles.`
  },
  {
    pillar: `Implementation`,
    project: `Digital Delivery Awareness & Enablement`,
    updates: `Not started. Campaign and training development upcoming.`,
    pct: 0,
    pm: `Scott Chatterton`,
    description: `Create awareness campaign materials, develop enablement training modules, and publish adoption success metrics.`
  },
  {
    pillar: `Implementation`,
    project: `Org Tech Change Management Capabilities`,
    updates: `Not started. Playbook and adoption readiness assessments pending.`,
    pct: 0,
    pm: `Nicole Damen`,
    description: `Develop change management playbook, create adoption readiness assessments, and publish communication templates for technology initiatives.`
  },
  {
    pillar: `Quality`,
    project: `QC / Design Review Standards`,
    updates: `Not started. Standardized QC workflow and template development upcoming.`,
    pct: 0,
    pm: `Steve Walz`,
    description: `Develop standardized QC workflows, create design review templates, and publish best practices for quality assurance.`
  },
  {
    pillar: `Quality`,
    project: `Model Health Monitoring`,
    updates: `Bentley broken-reference tool in active pilot. Civil 3D using Civil Collaboration tool. Revit leveraging Guardian.`,
    pct: 40,
    pm: `Steve Walz`,
    description: `Implement model health monitoring tools, define compliance metrics, and publish remediation guidelines for model integrity.`
  },
  {
    pillar: `Quality`,
    project: `Bluebeam — Usage, Training & Standardization`,
    updates: `Usage standards and training curriculum in early development.`,
    pct: 10,
    pm: `Adam Serock`,
    description: `Develop Bluebeam usage standards, create training curriculum, and publish dashboards for cost and markup visibility.`
  },
  {
    pillar: `Quality`,
    project: `IP Protection & Content Watermarking`,
    risks: `ENG content watermarking is behind the ABG timeline; needs a dedicated resource to finish before the July target.`,
    updates: `Revit ABG content fully marked. ENG watermarking in progress; July completion targeted.`,
    pct: 55,
    pm: `Dwayne Hansen`,
    description: `Develop watermarking protocols, implement IP protection workflows, and publish content management guidelines.`
  },
  {
    pillar: `Technology Innovation`,
    project: `Agentic AI Framework with MCP`,
    risks: `Needs an approved business case before scaling beyond the pilot; without it, funding for phase 2 is at risk.`,
    updates: `Internal MCP (RBG) connects Revit & Civil 3D. Autodesk IS Quality Copilot engagement starts June.`,
    pct: 25,
    pm: `Dwayne Hansen`,
    description: `Develop AI integration architecture, implement MCP capabilities, and publish governance for AI-enabled workflows.`
  },
  {
    pillar: `Technology Innovation`,
    project: `Sandbox Environments for Emerging Tech`,
    updates: `Not started. Secure sandbox architecture design pending.`,
    pct: 0,
    pm: `Mitch Williams`,
    description: `Create secure sandbox environments, define usage protocols, and publish onboarding documentation for innovation testing.`
  },
  {
    pillar: `Technology Innovation`,
    project: `Immersive 3D Training Environment from BIM`,
    updates: `TIRC funding and support presentation currently in progress.`,
    pct: 0,
    pm: `Dennis Ekk`,
    description: `Develop VR/MR/XR testing sandbox, create evaluation metrics for immersive tech, and publish enablement guides for adoption.`
  },
  {
    pillar: `Technology Innovation`,
    project: `Enterprise-wide DDD Automation Tool`,
    updates: `Deployment framework in scoping; enterprise rollout targeted for July 2026.`,
    pct: 25,
    pm: `Nicole Damen / N. Kanapuram`,
    description: `Create enterprise deployment framework, develop user enablement training, and publish governance for automation tool adoption.`
  },
  {
    pillar: `Technology Innovation`,
    project: `HDR DMS Function Library (SDK/APIs)`,
    updates: `Phase 2 scoping underway. API evaluation frameworks completed and shared with IT Architecture.`,
    pct: 10,
    pm: `Zach Smith`,
    description: `Develop reusable SDK/API function library, create integration guides for DMS platforms, and publish automation best practices.`
  },
  {
    pillar: `Technology Innovation`,
    project: `5 High-Value DDD Automation Projects`,
    updates: `DDP automation in development. Federal QC Copilot mobilizing. Federal Project Setup scope complete.`,
    pct: 5,
    pm: `Zach Smith`,
    description: `Select priority automation use cases, develop proof-of-concept workflows, and publish success metrics for delivered projects.`
  }
];
