import assert from "node:assert/strict";
import test from "node:test";

import { renderPluginSurfaceDocument } from "./plugin-surface-renderer.mjs";

test("plugin-owned collection binding maps raw service data into a Surface document", () => {
  const route = {
    title: "Notices",
    document: {
      schemaVersion: 1,
      presentation: "collection",
      title: "Notices",
      subtitle: { literal: "Latest notices" },
      filters: [],
      collection: {
        source: "api.notices",
        item: {
          id: "url",
          title: "title",
          subtitle: { join: ["source", "date"] },
          body: { coalesce: ["summary", "content"] },
          tags: ["category", "targets"],
          filterValues: { category: "category" },
          action: { type: "openURL", url: "url" }
        }
      }
    }
  };

  const document = renderPluginSurfaceDocument(route, {
    api: {
      notices: [{
        url: "https://example.test/1",
        title: "Scholarship",
        source: "Student Office",
        date: "2026-07-28",
        summary: "Apply now",
        category: "장학",
        targets: ["재학생"]
      }]
    }
  });

  assert.equal(document.presentation, "collection");
  assert.equal(document.subtitle, "Latest notices");
  assert.deepEqual(document.items[0], {
    id: "https://example.test/1",
    title: "Scholarship",
    subtitle: "Student Office · 2026-07-28",
    body: "Apply now",
    tags: ["장학", "재학생"],
    filterValues: { category: "장학" },
    action: { type: "openURL", url: "https://example.test/1" }
  });
});

test("plugin-owned dashboard binding expands raw profile and table groups", () => {
  const route = {
    title: "Portal",
    document: {
      schemaVersion: 1,
      presentation: "dashboard",
      title: "Portal",
      sections: [
        {
          kind: "keyValue",
          id: { literal: "profile" },
          title: { literal: "Profile" },
          fields: [
            { id: "name", label: "Name", value: { path: "$.api.profile.name" } }
          ]
        },
        {
          kind: "tableGroup",
          source: "api.tables",
          id: "id",
          title: "title",
          columns: "columns",
          rows: "rows"
        }
      ]
    }
  };

  const document = renderPluginSurfaceDocument(route, {
    api: {
      profile: { name: "Test Student" },
      tables: [{
        id: "grades",
        title: "Grades",
        columns: ["Course", "Grade"],
        rows: [["Data Structures", "A+"]]
      }]
    }
  });

  assert.deepEqual(document.sections, [
    {
      id: "profile",
      title: "Profile",
      subtitle: null,
      systemImage: null,
      kind: "keyValue",
      fields: [{ id: "name", label: "Name", value: "Test Student" }]
    },
    {
      id: "grades",
      title: "Grades",
      subtitle: null,
      systemImage: null,
      kind: "table",
      columns: ["Course", "Grade"],
      rows: [["Data Structures", "A+"]]
    }
  ]);
});
