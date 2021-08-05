import {cognitoLoginUrl, clientId} from "./config.js";

const sha256 = async (str) => {
	return await crypto.subtle.digest("SHA-256", new TextEncoder().encode(str));
};

const generateNonce = async () => {
	const hash = await sha256(crypto.getRandomValues(new Uint32Array(4)).toString());
	// https://developer.mozilla.org/en-US/docs/Web/API/SubtleCrypto/digest
	const hashArray = Array.from(new Uint8Array(hash));
	return hashArray.map(b => b.toString(16).padStart(2, "0")).join("");
};

const base64URLEncode = (string) => {
	return btoa(String.fromCharCode.apply(null, new Uint8Array(string)))
		.replace(/\+/g, "-")
		.replace(/\//g, "_")
		.replace(/=+$/, "")
};

const redirectToLogin = async () => {
	const state = await generateNonce();
	const codeVerifier = await generateNonce();
	sessionStorage.setItem(state, codeVerifier);
	const codeChallenge = base64URLEncode(await sha256(codeVerifier));
	window.location = `${cognitoLoginUrl}/login?response_type=code&client_id=${clientId}&state=${state}&code_challenge_method=S256&code_challenge=${codeChallenge}&redirect_uri=${window.location.origin}`;
};

document.querySelector("#loginButton").addEventListener("click", () => {
	redirectToLogin();
});

const init = async (tokens) => {
	console.log(tokens);
	const access_token = tokens.access_token;

	try {
		const apiRes = await fetch("/api/user", {
			headers: new Headers({"Authorization": `Bearer ${access_token}`}),
		});
		if (!apiRes.ok) {
			throw new Error(apiRes);
		}
		const apiResp = await apiRes.json();
		document.querySelector("#user").innerText = `You are signed in as ${apiResp.userId}`;
	}catch(e) {
		console.error(e);
		document.querySelector("#user").innerText = `Failed to get userid. Are you logged in with a valid token?`;
	}

	const refreshStatus = [];
	let currentId = 0;
	const doRefreshStatus = async () => {
		refreshStatus.reduce(async (memo, fn) => {
			await memo;
			return fn();
		}, Promise.resolve());
	};

	const refreshStatusButton = document.querySelector("#refreshStatus");
	refreshStatusButton.addEventListener("click", async () => {
		refreshStatusButton.disabled = true;
		await doRefreshStatus();
		refreshStatusButton.disabled = false;
	});

	const insertTokens = (parent, id, tokens) => {
		const table = document.querySelector("#tokens tbody");
		const row = table.insertRow();
		row.insertCell().innerText = parent;
		row.insertCell().innerText = id;
		row.insertCell().innerText = `${tokens.refresh_token ? "refresh_token\n" : ""}${tokens.access_token ? "access_token\n" : ""}${tokens.id_token ? "id_token" : ""}`;
		const buttonsCell = row.insertCell();
		if (tokens.refresh_token) {
			buttonsCell.innerHTML = `
	<button class="revoke">Revoke token</button>
	<button class="request">Refresh token</button>
			`;
			const revokeButton = buttonsCell.querySelector(".revoke");
			revokeButton.addEventListener("click", async () => {
				revokeButton.disabled = true;
				const res = await fetch(`${cognitoLoginUrl}/oauth2/revoke`, {
					method: "POST",
					headers: new Headers({"content-type": "application/x-www-form-urlencoded"}),
					body: Object.entries({
						"token": tokens.refresh_token,
						"client_id": clientId,
					}).map(([k, v]) => `${k}=${v}`).join("&"),
				});
				if (!res.ok) {
					throw new Error(await res.json());
				}
				await doRefreshStatus();
			});
			const requestButton = buttonsCell.querySelector(".request");
			requestButton.addEventListener("click", async () => {
				requestButton.disabled = true;
				const res = await fetch(`${cognitoLoginUrl}/oauth2/token`, {
					method: "POST",
					headers: new Headers({"content-type": "application/x-www-form-urlencoded"}),
					body: Object.entries({
						"grant_type": "refresh_token",
						"client_id": clientId,
						"redirect_uri": window.location.origin,
						"refresh_token": tokens.refresh_token,
					}).map(([k, v]) => `${k}=${v}`).join("&"),
				});
				if (!res.ok) {
					throw new Error(await res.json());
				}
				const newTokens = await res.json();
				insertTokens(id, currentId++, newTokens);
				await doRefreshStatus();
				requestButton.disabled = false;
			});
		}
		const statusCell = row.insertCell();
		refreshStatus.push(async () => {
			statusCell.innerHTML = "";
			const userInfoRes = await fetch(`${cognitoLoginUrl}/oauth2/userInfo`, {
				headers: new Headers({"Authorization": `Bearer ${tokens.access_token}`}),
			});
			const apiRes = await fetch("/api/user", {
				headers: new Headers({"Authorization": `Bearer ${tokens.access_token}`}),
			});
			const apiResIdToken = await fetch("/api/user", {
				headers: new Headers({"Authorization": `Bearer ${tokens.id_token}`}),
			});
			statusCell.innerText = `userInfo: ${userInfoRes.ok}\napi access_token: ${apiRes.ok}\napi id_token: ${apiResIdToken.ok}`;
		});
	}
	insertTokens(null, currentId++, tokens);
	await doRefreshStatus();
};

const searchParams = new URL(location).searchParams;

if (searchParams.get("code") !== null) {
	window.history.replaceState({}, document.title, "/");
	const state = searchParams.get("state");
	const codeVerifier = sessionStorage.getItem(state);
	sessionStorage.removeItem(state);
	if (codeVerifier === null) {
		throw new Error("Unexpected code");
	}
	const res = await fetch(`${cognitoLoginUrl}/oauth2/token`, {
		method: "POST",
		headers: new Headers({"content-type": "application/x-www-form-urlencoded"}),
		body: Object.entries({
			"grant_type": "authorization_code",
			"client_id": clientId,
			"code": searchParams.get("code"),
			"code_verifier": codeVerifier,
			"redirect_uri": window.location.origin,
		}).map(([k, v]) => `${k}=${v}`).join("&"),
	});
	if (!res.ok) {
		throw new Error(await res.json());
	}
	const tokens = await res.json();
	localStorage.setItem("tokens", JSON.stringify(tokens));

	init(tokens);
}else {
	if (localStorage.getItem("tokens")) {
		const tokens = JSON.parse(localStorage.getItem("tokens"));
		init(tokens);
	}else {
		redirectToLogin();
	}
}
