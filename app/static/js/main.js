document.addEventListener("DOMContentLoaded", () => {
    // Mobile sidebar open/close.
    document.querySelectorAll("[data-sidebar-toggle]").forEach((element) => {
        element.addEventListener("click", () => {
            const sidebar = document.getElementById("sidebar");
            const overlay = document.querySelector(".sidebar-overlay");

            if (!sidebar) return;

            sidebar.classList.toggle("open");
            overlay?.classList.toggle("visible");
        });
    });

    // Automatically dismiss flash messages.
    document.querySelectorAll(".flash-message").forEach((message) => {
        window.setTimeout(() => {
            message.style.opacity = "0";
            message.style.transform = "translateY(-5px)";

            window.setTimeout(() => message.remove(), 250);
        }, 5000);
    });

    // Add CSRF header to same-origin POST requests made with fetch().
    const originalFetch = window.fetch.bind(window);

    window.fetch = (resource, options = {}) => {
        const method = (options.method || "GET").toUpperCase();

        if (method !== "GET" && method !== "HEAD") {
            const token = document.querySelector(
                'meta[name="csrf-token"]'
            )?.content;

            if (token) {
                const headers = new Headers(options.headers || {});
                headers.set("X-CSRF-Token", token);
                options = { ...options, headers };
            }
        }

        return originalFetch(resource, options);
    };
});