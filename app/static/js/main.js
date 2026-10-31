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

// Login page animations
function staxioLoginInit() {
    var card = document.querySelector('.auth-card');
    if (!card) return;

    var reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    var easing = 'cubic-bezier(0.22, 1, 0.36, 1)';

    // Slide an element in from a direction after an optional delay
    function staxioLoginSlide(el, dx, dy, delay) {
        if (!el || !el.animate || reduceMotion) return;
        el.animate(
            [
                { opacity: 0, transform: 'translate(' + dx + 'px, ' + dy + 'px)' },
                { opacity: 1, transform: 'translate(0, 0)' }
            ],
            { duration: 650, delay: delay, easing: easing, fill: 'backwards' }
        );
    }

    // Side panel and card enter from opposite sides
    staxioLoginSlide(document.querySelector('.auth-aside'), -40, 0, 0);
    staxioLoginSlide(card, 40, 0, 120);

    // Stagger the content inside the card
    var items = card.querySelectorAll(
        '.auth-kicker, h2, .auth-subtitle, .auth-form > *, .auth-bottom, .back-home'
    );
    items.forEach(function (el, i) {
        staxioLoginSlide(el, 0, 18, 300 + i * 90);
    });

    // Show or hide the password
    var toggle = document.getElementById('staxio-password-toggle');
    var passwordInput = card.querySelector('input[type="password"]');
    if (toggle && passwordInput) {
        toggle.addEventListener('click', function () {
            var showing = passwordInput.type === 'text';
            passwordInput.type = showing ? 'password' : 'text';
            toggle.setAttribute('aria-pressed', String(!showing));
            toggle.setAttribute('aria-label', showing ? 'Show password' : 'Hide password');
            toggle.innerHTML = showing
                ? '<i class="fa-solid fa-eye"></i>'
                : '<i class="fa-solid fa-eye-slash"></i>';
        });
    }

    // Loading state on submit (browser validation runs first)
    var form = document.getElementById('staxio-login-form');
    var submitBtn = document.getElementById('staxio-login-submit');
    if (form && submitBtn) {
        form.addEventListener('submit', function () {
            submitBtn.disabled = true;
            submitBtn.style.opacity = '0.75';
            submitBtn.innerHTML = '<i class="fa-solid fa-spinner fa-spin"></i> Signing in…';
        });
    }
}

document.addEventListener('DOMContentLoaded', staxioLoginInit);