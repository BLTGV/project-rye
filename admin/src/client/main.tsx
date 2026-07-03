import React from "react";
import ReactDOM from "react-dom/client";
import { BrowserRouter, Routes, Route } from "react-router";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AppLayout } from "./components/AppLayout";
import { InstanceProvider } from "./lib/instance";
import { DashboardPage } from "./pages/DashboardPage";
import { SearchPage } from "./pages/SearchPage";
import { NodeDetailPage } from "./pages/NodeDetailPage";
import { GraphPage } from "./pages/GraphPage";
import { EventsPage } from "./pages/EventsPage";
import { DisputesPage } from "./pages/DisputesPage";
import { KnowledgeMapPage } from "./pages/KnowledgeMapPage";
import { CandidateReviewPage } from "./pages/CandidateReviewPage";
import { SalesWorkspacePage } from "./pages/SalesWorkspacePage";
import { ProjectsWorkspacePage } from "./pages/ProjectsWorkspacePage";
import "./styles/app.css";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: { refetchOnWindowFocus: false, staleTime: 30_000 },
  },
});

const root = document.getElementById("root")!;
ReactDOM.createRoot(root).render(
  <React.StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <InstanceProvider>
          <Routes>
            <Route element={<AppLayout />}>
              <Route path="/" element={<DashboardPage />} />
              <Route path="/sales" element={<SalesWorkspacePage />} />
              <Route path="/projects" element={<ProjectsWorkspacePage />} />
              <Route path="/search" element={<SearchPage />} />
              <Route path="/knowledge" element={<KnowledgeMapPage />} />
              <Route path="/review" element={<CandidateReviewPage />} />
              <Route path="/nodes/:id" element={<NodeDetailPage />} />
              <Route path="/graph" element={<GraphPage />} />
              <Route path="/graph/:id" element={<GraphPage />} />
              <Route path="/events" element={<EventsPage />} />
              <Route path="/disputes" element={<DisputesPage />} />
            </Route>
          </Routes>
        </InstanceProvider>
      </BrowserRouter>
    </QueryClientProvider>
  </React.StrictMode>
);
