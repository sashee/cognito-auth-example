const jwt = require("jsonwebtoken");
const jwkToPem = require("jwk-to-pem");
const fetch = require("node-fetch");
const util = require("util");

const getOpenIdConfig = (() => {
	let prom = undefined;
	return () => prom = (prom || (async () => {
		const openIdRes = await fetch(`https://cognito-idp.${process.env.AWS_REGION}.amazonaws.com/${process.env.USER_POOL_ID}/.well-known/openid-configuration`);
		if (!openIdRes.ok) {
			throw new Error(openIdRes);
		}
		const openIdJson = await openIdRes.json();
		const res = await fetch(openIdJson.jwks_uri);
		if (!res.ok) {
			throw new Error(res);
		}
		const jwks = await res.json();
		return {
			openIdJson,
			jwks,
		};
	})());
})();

module.exports.handler = async (event) => {
	const auth_token = event.headers.authorization.split("Bearer ")[1];
	const openIdConfig = await getOpenIdConfig();
	const decoded = jwt.decode(auth_token, {complete: true});
	const jwk = openIdConfig.jwks.keys.find(({kid}) => kid === decoded.header.kid);
	const pem = jwkToPem(jwk);
	const token_use = decoded.payload.token_use;
	if (token_use === "access") {
		await util.promisify(jwt.verify.bind(jwt))(auth_token, pem, { algorithms: ["RS256"], issuer: openIdConfig.openIdJson.issuer});

		if (decoded.payload.client_id !== process.env.CLIENT_ID) {
			throw new Error(`ClientId must be ${process.env.CLIENT_ID}, got ${decoded.payload.client_id}`);
		}

		const openIdRes = await fetch(openIdConfig.openIdJson.userinfo_endpoint, {
			headers: new fetch.Headers({"Authorization": `Bearer ${auth_token}`}),
		});
		if (!openIdRes.ok) {
			throw new Error(JSON.stringify(await openIdRes.json()));
		}
	}else if (token_use === "id") {
		await util.promisify(jwt.verify.bind(jwt))(auth_token, pem, { algorithms: openIdConfig.openIdJson.id_token_signing_alg_values_supported, issuer: openIdConfig.openIdJson.issuer, audience: process.env.CLIENT_ID});
	}else {
		throw new Error(`token_use must be "access" or "id", got ${token_use}`);
	}
	const userId = decoded.payload.sub;

	return {userId};
};
